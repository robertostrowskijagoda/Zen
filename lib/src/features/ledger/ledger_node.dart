import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/app/peer_version.dart';
import 'package:zen/src/core/ledger/blob_store.dart';
import 'package:zen/src/core/ledger/hlc.dart';
import 'package:zen/src/core/ledger/ledger_archive.dart';
import 'package:zen/src/core/ledger/ledger_author.dart';
import 'package:zen/src/core/ledger/ledger_codec.dart';
import 'package:zen/src/core/ledger/ledger_identity.dart';
import 'package:zen/src/core/ledger/ledger_replicator.dart';
import 'package:zen/src/core/ledger/ledger_store.dart';
import 'package:zen/src/core/ledger/log_entry.dart';
import 'package:zen/src/core/ledger/space_policy.dart';
import 'package:zen/src/core/logging/zen_log.dart';
import 'package:zen/src/features/health/clock_skew_tracker.dart';
import 'package:zen/src/features/ledger/audience_keys.dart';
import 'package:zen/src/features/ledger/bridge_book.dart';
import 'package:zen/src/features/ledger/ledger_identity_store.dart';
import 'package:zen/src/features/ledger/met_attestation.dart';
import 'package:zen/src/features/runtime/signal_transport.dart';
import 'package:zen/src/features/social/peer_share_codec.dart';

/// Introduces this device's account to a friend: `{type, cert}`.
const String kLedgerHelloType = 'lg_hello';

/// Gives a friend the audience keys their level allows: `{type, items}`.
const String kLedgerKeysType = 'lg_keys';

/// Passes on known mesh bridges: `{type, items: [announcement…]}`.
const String kLedgerBridgesType = 'lg_bridges';

/// Asks a friend to check from outside that this computer can be reached
/// at `uri` (before announcing it as a bridge): `{type, id, uri}`.
const String kLedgerReachType = 'lg_reach';

/// The friend's answer: `{type, id, ok}`.
const String kLedgerReachOkType = 'lg_reach_ok';

/// Checks for others a friend may ask for per minute.
const int kReachChecksPerMinute = 4;

/// What friends said about this computer's address.
enum ReachResult {
  /// At least one friend connected and got the mesh greeting.
  reachable,

  /// Friends tried and could not connect.
  unreachable,

  /// Nobody answered (no friend online right now).
  noAnswer,
}

/// Where a device of an account can be reached (several devices): an
/// entry of this kind in the account's `acts` space, `{address, name}`.
/// Only a claim (the account signs it, not whoever is at that address):
/// the address counts once a hello from there proves the device key.
const String kDeviceRecordKind = 'device';

/// The sealed backup of friends and groups in the account's `private`
/// space (only its own devices can open it; friends keep a copy).
const String kContactsKind = 'contacts';

/// A friend removed or a group left on one device (so the others follow):
/// sealed `{a}` or `{g}` in the private space.
const String kContactRemovedKind = 'contact_removed';

/// A message sent from one device, for the account's other devices:
/// sealed `{peer, m, f?}` in the `own` space.
const String kChatCopyKind = 'chat';

/// The whole chat history of one device for a newly linked device: sealed
/// `{f}` (an encrypted file) in the `own` space.
const String kChatHistoryKind = 'chat_history';

/// A friend's new entries handed over through the reliable queue (they may
/// have waited in this device's mailboxes): `{type, entries}`, taken like
/// those of a sync (`ledger_mail_push.dart`).
const String kLedgerPushType = 'lg_push';

/// Own devices share their audience keys and friend levels:
/// `{type, own, levels}`.
const String kLedgerSiblingType = 'lg_sibling';

/// One device of an account, as this node knows it.
@immutable
final class AccountDevice {
  const AccountDevice({
    required this.account,
    required this.device,
    required this.name,
    this.address,
    this.isThis = false,
    this.issued = 0,
  });

  final String account;

  /// Device key (id).
  final String device;
  final String name;

  /// Mesh address, once known.
  final String? address;

  /// This very device.
  final bool isThis;

  /// When the account certified it.
  final int issued;
}

final class _DeviceRef {
  _DeviceRef(this.account, this.device, this.name, this.at);

  final String account;
  final String device;
  final String name;

  /// HLC millis of the record it came from (0: learnt from a hello).
  int at;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'a': account,
    'd': device,
    'n': name,
    't': at,
  };
}

/// What a device record says and nobody proved yet: [device] of [account]
/// is at [address]. The address is greeted; it becomes a device only when
/// a hello from there is signed by [device].
final class _DeviceHint {
  _DeviceHint(this.account, this.device, this.name, this.at, this.address);

  final String account;
  final String device;
  final String name;

  /// HLC millis of the record.
  final int at;

  /// Normalised mesh address it names.
  final String address;
}

/// Spaces of a friend's account this device keeps and follows. `private`
/// is sealed for the account's own devices: friends only keep a copy, so a
/// new or recovered device gets its friends and groups back.
const List<String> kFollowedFriendSpaces = <String>[
  'feed',
  'acts',
  'profile',
  'private',
];

/// Spaces anyone may read (followers who are not friends).
const List<String> kPublicSpaceKinds = <String>['feed', 'profile'];

/// Frames a stranger (not a friend) may send per minute before the rest
/// is dropped. Counted per /64 network: a mesh node may send from any
/// address inside its own /64.
const int kStrangerFramesPerMinute = 30;

/// Frames all strangers together may send per minute.
const int kStrangerFramesPerMinuteTotal = 1200;

/// The ledger engine wired into the app: identity, storage on disk,
/// replication over the app's signal transport with friends.
///
/// Friends are identified by their mesh address (as today); the first time
/// two friends talk, they exchange `lg_hello` with their device certificate,
/// which tells each side the other's account key and so which spaces to
/// follow.
final class LedgerNode {
  LedgerNode({
    required this.transport,
    required this.disk,
    required this.friendAddresses,
    this.deviceName = 'Urządzenie',
    HlcClock? clock,
    this.helloInterval = const Duration(minutes: 10),
    BridgeBook? bridges,
    this.onBridgesChosen,
    this.bridgeConnections = 5,
    bool Function()? autoDownloadMedia,
    this.syncInterval = const Duration(minutes: 10),
    bool startSuspended = false,
    this.createIdentity = true,
    BridgeProbe? reachProbe,
    this.localAddress,
    this.localSessionKey,
    this.greetAlso,
  }) : _clock = clock ?? HlcClock(wallClock: friendsAgreedTime),
       _reachProbe = reachProbe ?? yggBridgeProbe,
       bridges = bridges ?? BridgeBook(),
       autoDownloadMedia = autoDownloadMedia ?? _always,
       _suspended = startSuspended {
    if (startSuspended) {
      _resumed = Completer<void>();
    }
  }

  /// How often friends are greeted again (catching up both ways, retrying
  /// unfinished photos and videos), even when nothing else happens.
  final Duration syncInterval;

  /// False for a second copy of the node (the Android background service):
  /// it must use the identity the app created, never make its own.
  final bool createIdentity;

  /// While suspended another process owns the ledger on disk (the Android
  /// background service while the app is not on screen): this node neither
  /// reads frames nor writes. [resume] catches up with what was written.
  bool _suspended;
  Completer<void>? _resumed;
  bool _loaded = false;
  Timer? _syncTimer;

  bool get isSuspended => _suspended;

  /// Whether the ledger was read from disk (it may be suspended since).
  bool get isLoaded => _loaded;

  /// Set once [suspend] or [resume] is called by whoever hands the disk
  /// over (the Android background bridge).
  bool _ownershipManaged = false;

  /// Safety net for a node started suspended that nobody ever resumed (the
  /// bridge failed early): take the disk after all.
  Future<void> resumeIfUnmanaged() async {
    if (!_ownershipManaged && _suspended && !_loaded) {
      logZenWarning('Dziennik nie dostał zgody na start; startuję sam.');
      await resume();
    }
  }

  static bool _always() => true;

  /// Whether photos and videos of friends' posts download on their own
  /// (the "pobieranie mediów" setting; on by default).
  final bool Function() autoDownloadMedia;

  /// Chunks a stranger may ask for in one message (media are encrypted, so
  /// serving them is harmless, but not unlimited).
  static const int strangerChunksPerRequest = 4;

  static const String _peersKey = 'ledger/peers';
  static const String _followingKey = 'ledger/following';
  static const String _keyringKey = 'ledger/audience';
  static const String _levelsKey = 'ledger/levels';
  static const String _metPendingKey = 'ledger/met_pending';

  /// People met in person whose account is not known yet (a friend request
  /// not answered): normalised address → when they met. The attestation is
  /// signed once their hello tells the account.
  final Map<String, int> _metPending = <String, int>{};

  /// How long a meeting waits for the other's account, and how many wait.
  static const int _metPendingMs = 30 * 24 * 3600 * 1000;
  static const int _maxMetPending = 200;

  /// Audience keys: ours (every generation) and those friends gave us.
  final AudienceKeyring keyring = AudienceKeyring();

  /// Private level of each friend (normalised address); default "Znajomy".
  final Map<String, FriendLevel> _levels = <String, FriendLevel>{};

  /// Decrypted bodies of sealed entries, by entry id.
  final Map<String, Map<String, dynamic>> _opened =
      <String, Map<String, dynamic>>{};
  final StreamController<void> _openedChanges =
      StreamController<void>.broadcast();
  StreamSubscription<LogEntry>? _added;
  final StreamController<String> _blobDone =
      StreamController<String>.broadcast();

  /// Ids of media that finished downloading.
  Stream<String> get mediaCompleted => _blobDone.stream;
  static const String _bridgesKey = 'ledger/bridges';
  static const String _bridgeKeyKey = 'ledger/bridge_key';

  /// Mesh entry points learnt from friends (and this device's own).
  final BridgeBook bridges;

  /// Receives the bridges to connect to whenever the choice changes (the
  /// runtime adds them as mesh peers).
  final void Function(List<String> uris)? onBridgesChosen;
  final int bridgeConnections;

  /// This device's own mesh address ('' while unknown).
  final String Function()? localAddress;

  /// Fingerprint (hex) of this node's post-quantum device key ('' while
  /// unknown): the hello signs it together with the address, binding the
  /// session layer (pq_session.go) to this device's hybrid key.
  final String Function()? localSessionKey;

  /// Pins device keys (address → fingerprint) in the bridge: keys proven
  /// by hybrid-signed hellos and named by friends' signed device records.
  /// With `force` the key replaces a different pin (a known friend's
  /// signed hello contradicts the session it came over).
  void Function(Map<String, String> keys, {bool force})? onSessionKeys;

  /// A hello signed by [address]'s device names another device key than
  /// the session it came over: someone else holds that address's node key.
  /// The hello is refused; the app warns in the chat.
  void Function(String address)? onDeviceKeyMismatch;

  /// Device keys proven or named per address (normalised), for the friend
  /// list ([sessionKeyOf]). In memory: hellos and records bring them back.
  final Map<String, String> _sessionKeys = <String, String>{};
  static const int _maxSessionKeys = 5000;

  /// Addresses already warned about, with when (a warning an hour at most).
  final Map<String, int> _keyWarnedAt = <String, int>{};

  /// The device key [address] proved in a hello signed by its hybrid
  /// device key (or a friend's signed device record names), or null.
  String? sessionKeyOf(String address) =>
      _sessionKeys[PeerShareCodec.normalizeAddress(address)];

  /// Other addresses to greet now and then (group members who are not
  /// friends): their answer tells which account they belong to, so their
  /// other devices are recognised too.
  final Iterable<String> Function()? greetAlso;

  /// Extra fields for the hello sent to a (normalised) address: a signed
  /// follow notice for someone this account follows. Peers that do
  /// not know a field ignore it.
  Map<String, dynamic>? Function(String address)? helloExtras;

  /// Called for every proven hello from someone who is neither a friend
  /// nor this account ([account] at [address]), with its payload (follow
  /// notices).
  void Function(String address, String account, Map<String, dynamic> payload)?
  onStrangerHello;

  /// This device's own mesh address ('' when unknown).
  String get ownAddress => _ownAddress;

  /// Greets [address] now, friend or not (e.g. to tell someone this
  /// account stopped following them).
  void greet(String address) => _hello(address, force: true);

  /// Devices of accounts that are neither ours nor friends' (group
  /// members), learnt from proven hellos. Kept in memory only.
  final Map<String, _DeviceRef> _strangerDevices = <String, _DeviceRef>{};
  static const int _maxStrangerDevices = 2000;

  final StreamController<LogEntry> _ownEntries =
      StreamController<LogEntry>.broadcast();
  final Set<String> _ownApplied = <String>{};
  static const String _ownAppliedKey = 'ledger/own_applied';

  /// Entries another device of this account wrote for the others (chat
  /// copies, history, removed contacts), once readable.
  Stream<LogEntry> get ownEntries => _ownEntries.stream;

  String get _ownAddress =>
      PeerShareCodec.normalizeAddress(localAddress?.call() ?? '');

  /// Other devices: this account's own and friends' other devices, by
  /// normalised mesh address. Only devices that proved the address (a
  /// hello from it signed by their key, see [_learnDevice]): everything
  /// that routes to an account's devices relies on this.
  final Map<String, _DeviceRef> _devices = <String, _DeviceRef>{};

  /// Addresses device records claim, not proven yet, by device key (one
  /// per device: its newest record). Kept in memory only: the records stay
  /// in the store and are read again at start.
  final Map<String, _DeviceHint> _deviceHints = <String, _DeviceHint>{};
  static const int _maxHintsPerAccount = 16;

  /// Addresses to greet even though nobody vouched for them yet: the
  /// device this one was linked from, or the friends who helped recover
  /// the account. They answer with their certificate.
  final Set<String> _deviceSeeds = <String>{};
  static const String _devicesKey = 'ledger/devices';
  final StreamController<void> _devicesChanged =
      StreamController<void>.broadcast();
  final StreamController<void> _contactsChanged =
      StreamController<void>.broadcast();
  StreamSubscription<void>? _storeChanged;

  /// Fires when the known devices (own or friends') change.
  Stream<void> get devicesChanged => _devicesChanged.stream;

  /// Fires when another own device saved a newer backup of friends and
  /// groups (read it with [latestContacts]).
  Stream<void> get contactsChanged => _contactsChanged.stream;

  final StreamController<String> _peerGreeted =
      StreamController<String>.broadcast();

  /// A friend (or own device) proved who it is just now: a good moment to
  /// tell it news (a new version of the app).
  Stream<String> get peerGreeted => _peerGreeted.stream;

  /// Whether [address] is a friend's device (or one of this account's).
  bool isFriendAddress(String address) => _isFriend(address);

  /// How a friend's address is checked when they ask.
  final BridgeProbe _reachProbe;
  final Map<String, _ReachWait> _reachWaits = <String, _ReachWait>{};
  final List<int> _reachAnsweredAt = <int>[];
  List<String> _chosenBridges = const <String>[];

  final SignalTransport transport;
  final LedgerDisk disk;

  /// Current accepted friends, by mesh address.
  final Iterable<String> Function() friendAddresses;
  final String deviceName;
  final Duration helloInterval;
  final HlcClock _clock;

  late final LedgerStore store = LedgerStore(clock: _clock);
  late final BlobStore blobs = BlobStore(backend: DiskBlobChunkBackend(disk));
  late final LedgerArchive archive = LedgerArchive(disk: disk);
  late final LedgerReplicator replicator = LedgerReplicator(
    store: store,
    blobs: blobs,
    send: _send,
    peers: () => _knownFriends(),
    acceptsFrom: (String peer, String space) => _isFriend(peer)
        ? replicator.subscriptions.contains(space)
        : _followedSpaces(peer).contains(space) ||
              // Own entries are signed by own devices: whoever brings them
              // back (a seed while recovering) cannot have forged them.
              (_isSeed(peer) && _ownSpaces.contains(space)),
    // Chat copies never leave this account's own devices. A space of a kind
    // this build does not know (kept for a newer build) goes only to
    // friends: its rules for who may read it are not known here.
    servesTo: (String peer, String space) =>
        (isKnownSpace(space) && !space.startsWith('own/')) ||
        _isSibling(peer) ||
        _forwardsUnknown(peer, space),
    forwardsFrom: _takesUnknownFrom,
  );

  /// Whether unknown-kind [space] may be given to [peer].
  bool _forwardsUnknown(String peer, String space) =>
      !isKnownSpace(space) &&
      defaultSpacePolicy(space) != null &&
      _isFriend(peer);

  /// Whether unknown-kind [space] may be taken from [peer] to pass on: only
  /// spaces of this account or of a friend's (so they do not spread past
  /// the owner's friends), within the store's caps on writers and bytes
  /// ([UnknownAccountSpacePolicy]) and a cap on how many such spaces are
  /// kept.
  bool _takesUnknownFrom(String peer, String space) {
    if (!_forwardsUnknown(peer, space)) {
      return false;
    }
    final String owner = space.substring(space.indexOf('/') + 1);
    if (owner != account && !_accounts.containsValue(owner)) {
      return false;
    }
    if (store.holdsSpace(space)) {
      return true;
    }
    int held = 0;
    for (final String s in store.spaces) {
      if (!isKnownSpace(s) && ++held >= kMaxUnknownSpaces) {
        return false;
      }
    }
    return true;
  }

  late final LedgerIdentity identity;
  late final LedgerAuthor author;

  /// Normalised friend address → account key, learnt from hellos.
  final Map<String, String> _accounts = <String, String>{};
  final Map<String, int> _helloSentAt = <String, int>{};

  /// Followed addresses (not friends) → account key ('' until known).
  final Map<String, String> _followed = <String, String>{};

  /// /64 network -> (minute, frames) for strangers.
  final Map<String, (int, int)> _strangerBudget = <String, (int, int)>{};
  static const int _maxStrangerNetworks = 5000;
  (int, int) _strangerTotal = (0, 0);
  StreamSubscription<SignalTransportFrame>? _frames;
  Future<void>? _started;
  bool _stopped = false;
  bool _ready = false;

  /// True once the identity is loaded and the archive is open.
  bool get isReady => _ready;

  String get account => identity.account;

  /// Friends whose accounts are known: normalised address → account key.
  Map<String, String> get friendAccounts =>
      Map<String, String>.unmodifiable(_accounts);

  /// Followed accounts whose key is known: normalised address → account.
  Map<String, String> get followedAccounts =>
      Map<String, String>.unmodifiable(<String, String>{
        for (final MapEntry<String, String> e in _followed.entries)
          if (e.value.isNotEmpty) e.key: e.value,
      });

  /// Addresses followed (with or without a known account yet).
  Iterable<String> get followedAddresses => _followed.keys;

  /// Account key of friend [address], once known.
  String? accountOf(String address) =>
      _accounts[PeerShareCodec.normalizeAddress(address)];

  /// Account key of [address] if it is a friend or a followed account.
  String? knownAccountOf(String address) {
    final String normalized = PeerShareCodec.normalizeAddress(address);
    final String? followed = _followed[normalized];
    return _accounts[normalized] ??
        (followed == null || followed.isEmpty ? null : followed);
  }

  /// Fires when sealed entries became readable (keys arrived).
  Stream<void> get openedChanges => _openedChanges.stream;

  /// What [entry] says: its body, or the decrypted one for a sealed entry
  /// (`null` when this device has no key for it).
  Map<String, dynamic>? bodyOf(LogEntry entry) =>
      isSealed(entry.body) ? _opened[entry.id] : entry.body;

  /// This account's private level for friend [address].
  FriendLevel levelOf(String address) {
    final String normalized = PeerShareCodec.normalizeAddress(address);
    final FriendLevel? direct = _levels[normalized];
    if (direct != null) {
      return direct;
    }
    // A friend's other device gets what the friend gets.
    final String? acc = _liveDevice(normalized)?.account;
    if (acc != null) {
      for (final MapEntry<String, String> e in _accounts.entries) {
        if (e.value == acc && _levels.containsKey(e.key)) {
          return _levels[e.key]!;
        }
      }
    }
    return FriendLevel.friend;
  }

  /// Changes a friend's level. Going down rotates the keys of the audiences
  /// they lose, so they cannot read anything written from now on.
  Future<void> setLevel(String address, FriendLevel level) async {
    await start();
    final String normalized = PeerShareCodec.normalizeAddress(address);
    final FriendLevel old = levelOf(normalized);
    if (old == level) {
      return;
    }
    _levels[normalized] = level;
    await _saveLevels();
    final Set<Audience> lost = audiencesFor(
      old,
    ).difference(audiencesFor(level));
    if (lost.isNotEmpty) {
      for (final Audience a in lost) {
        keyring.rotate(a, _clock.wallMillis());
      }
      await _saveKeyring();
      _sendKeysToAll();
    } else {
      _sendKeys(normalized);
    }
  }

  /// Encrypts [body] for [audience] (returned unchanged for public).
  Future<Map<String, dynamic>> seal(
    Audience audience,
    Map<String, dynamic> body,
  ) async {
    await start();
    if (audience == Audience.public) {
      return body;
    }
    return sealBody(body, keyring.current(audience), account: account);
  }

  Future<void> start() => _started ??= _start();

  Future<void> _start() async {
    // Started suspended: the disk belongs to someone else until [resume].
    // (No await otherwise: an extra async step changes nothing but timing.)
    final Completer<void>? gate = _resumed;
    if (gate != null) {
      await gate.future;
    }
    if (!createIdentity && !await LedgerIdentity.exists(disk)) {
      throw StateError(t('Brak tożsamości dziennika na tym urządzeniu.'));
    }
    final LedgerIdentity? existing = await LedgerIdentity.read(disk);
    LedgerIdentity loaded =
        existing ??
        await LedgerIdentity.loadOrCreate(disk, deviceName: deviceName);
    await store.directory.addCertificate(loaded.certificate);
    await archive.open(store, blobs);
    if (existing != null && archive.lostOwnLog(loaded.writer)) {
      // Our own log did not come back whole: entries others hold may be
      // missing here, and writing on would number new ones like them (a
      // fork everyone refuses for good). A new log goes on cleanly.
      logZenWarning('Własny dziennik niepełny; zaczynam nowy.');
      loaded = await loaded.withNewWriter(disk);
    }
    identity = loaded;
    author = LedgerAuthor(
      deviceKey: identity.deviceKey,
      certificate: identity.certificate,
      store: store,
      writer: identity.writer,
    );
    await _loadPeers();
    await _loadFollowing();
    await _loadKeys();
    await _loadBridges();
    await _loadDevices();
    await _loadOwnApplied();
    await _loadMetPending();
    await identity.rememberSelfKey(disk);
    for (final String kind in kAccountSpaceKinds) {
      replicator.subscribe(accountSpace(kind, account));
    }
    for (final String friendAccount in _accounts.values) {
      _followAccount(friendAccount);
    }
    for (final String followed in _followed.values) {
      if (followed.isNotEmpty) {
        _subscribePublic(followed);
      }
    }
    replicator.onBlobComplete = (String id) {
      if (!_blobDone.isClosed) {
        _blobDone.add(id);
      }
    };
    _added = store.added.listen((LogEntry e) {
      if (isSealed(e.body)) {
        unawaitedLogged(
          _open(<LogEntry>[e]),
          context: 'Odszyfrowanie wpisu nie udało się',
        );
      }
      if (e.account != account && autoDownloadMedia()) {
        _fetchMediaOf(e);
      }
      if (e.account == account &&
          e.device != identity.deviceKey.id &&
          e.space == accountSpace('own', account)) {
        // Files another own device sent: always fetched, from the others.
        _fetchMediaOf(e);
      }
      if (e.kind == kDeviceRecordKind) {
        unawaitedLogged(
          _onDeviceRecord(e),
          context: 'Odczyt urządzenia konta nie udał się',
        );
      }
    });
    _storeChanged = store.changed.listen((_) => _pruneRevoked());
    for (final String space in store.spaces.toList()) {
      if (space.startsWith('acts/')) {
        for (final LogEntry e in store.entries(space)) {
          if (e.kind == kDeviceRecordKind) {
            await _onDeviceRecord(e, quiet: true);
          }
        }
      }
    }
    await _open(_sealedEntries());
    _loaded = true;
    _ready = true;
    if (_suspended) {
      // Handed over while loading: stay quiet until [resume].
      await archive.pause();
      return;
    }
    _listen();
    _startSyncTimer();
    // Connect to the bridges known from before right away.
    _publishChoice();
    await greetFriends();
    await _publishOwnDevice();
  }

  void _listen() {
    _frames = transport.frames.listen(
      (SignalTransportFrame frame) => unawaitedLogged(
        _onFrame(frame),
        context: 'Obsługa wiadomości dziennika nie udała się',
      ),
    );
  }

  void _startSyncTimer() {
    _syncTimer?.cancel();
    if (syncInterval <= Duration.zero) {
      return;
    }
    _syncTimer = Timer.periodic(syncInterval, (_) {
      if (!_suspended && !_stopped) {
        unawaitedLogged(
          greetFriends(),
          context: 'Okresowa synchronizacja dziennika nie udała się',
        );
        unawaitedLogged(
          maintainBridges(),
          context: 'Sprawdzenie mostów nie udało się',
        );
      }
    });
  }

  /// Hands the ledger on disk to another process: stops listening, saves
  /// everything and stops writing until [resume].
  Future<void> suspend() async {
    _ownershipManaged = true;
    if (_suspended || _stopped) {
      return;
    }
    _suspended = true;
    _resumed = Completer<void>();
    _syncTimer?.cancel();
    await _frames?.cancel();
    _frames = null;
    if (_loaded) {
      await archive.pause();
    }
  }

  /// Takes the ledger back: reads what the other process wrote meanwhile
  /// (new posts, files, likes), then carries on.
  Future<void> resume() async {
    _ownershipManaged = true;
    if (!_suspended || _stopped) {
      return;
    }
    _suspended = false;
    final Completer<void>? gate = _resumed;
    _resumed = null;
    if (!_loaded) {
      // Never loaded: [start] goes on from where it waited.
      gate?.complete();
      return;
    }
    try {
      await archive.catchUp();
    } finally {
      gate?.complete();
    }
    _listen();
    _startSyncTimer();
    await greetFriends();
  }

  /// Sends a hello to every friend (again at most every [helloInterval]).
  Future<void> greetFriends() async {
    if (_suspended) {
      return;
    }
    for (final String friend in friendAddresses()) {
      _hello(friend);
    }
    for (final String device in <String>{
      ..._liveDeviceAddresses(),
      ..._deviceSeeds,
      // Claimed by a record: known once the device there answers.
      ..._hintAddresses(),
      ...?greetAlso?.call().map(PeerShareCodec.normalizeAddress),
    }) {
      if (device != _ownAddress) {
        _hello(device);
      }
    }
    _resumeMedia();
    replicator.retryBlobs();
    // A followed account answers a hello with its own, which starts a sync.
    // (Forced: the answer never answers back, so this cannot loop.)
    for (final String address in _followed.keys) {
      if (!_isFriend(address)) {
        _hello(address, force: true);
      }
    }
  }

  /// Follows the public posts and profile of [address] — anyone, no
  /// consent needed. Friends are followed anyway.
  Future<void> follow(String address) async {
    await start();
    final String normalized = PeerShareCodec.normalizeAddress(address);
    if (_isFriend(normalized) || _followed.containsKey(normalized)) {
      return;
    }
    _followed[normalized] = '';
    await _saveFollowing();
    _hello(normalized, force: true);
  }

  Future<void> unfollow(String address) async {
    await start();
    final String normalized = PeerShareCodec.normalizeAddress(address);
    final String? acc = _followed.remove(normalized);
    if (acc == null) {
      return;
    }
    if (acc.isNotEmpty &&
        !_accounts.containsValue(acc) &&
        !_followed.containsValue(acc)) {
      for (final String kind in kPublicSpaceKinds) {
        replicator.unsubscribe(accountSpace(kind, acc));
      }
    }
    await _saveFollowing();
  }

  bool isFollowing(String address) =>
      _followed.containsKey(PeerShareCodec.normalizeAddress(address));

  /// Call when the friend list changed (someone added or removed).
  Future<void> onFriendsChanged() async {
    if (_started == null) {
      return;
    }
    await _started;
    final Set<String> friends = friendAddresses()
        .map(PeerShareCodec.normalizeAddress)
        .toSet();
    final List<String> gone = _accounts.keys
        .where((String a) => !friends.contains(a))
        .toList();
    final Set<Audience> lost = <Audience>{};
    for (final String address in gone) {
      lost.addAll(audiencesFor(levelOf(address)));
      _levels.remove(address);
      final String? acc = _accounts.remove(address);
      if (acc != null && !_accounts.containsValue(acc)) {
        for (final String kind in kFollowedFriendSpaces) {
          replicator.unsubscribe(accountSpace(kind, acc));
        }
      }
    }
    if (gone.isNotEmpty) {
      await _savePeers();
      await _saveLevels();
      // A removed friend keeps what they could read, nothing new.
      for (final Audience a in lost) {
        keyring.rotate(a, _clock.wallMillis());
      }
      await _saveKeyring();
      _sendKeysToAll();
    }
    await greetFriends();
  }

  /// Writes an entry into one of this account's spaces.
  Future<LogEntry> publish(
    String kind,
    Map<String, dynamic> body, {
    String spaceKind = 'feed',
    List<String> blobs = const <String>[],
  }) async {
    await start();
    // Suspended: the other process owns the disk; wait for it back.
    final Completer<void>? gate = _resumed;
    if (gate != null) {
      await gate.future;
    }
    return author.append(
      accountSpace(spaceKind, account),
      kind,
      body,
      blobs: blobs,
    );
  }

  /// Entries of [spaceKind] of [ofAccount] (default: this account).
  List<LogEntry> entriesOf({String spaceKind = 'feed', String? ofAccount}) =>
      store.entries(accountSpace(spaceKind, ofAccount ?? account));

  bool _isFriend(String address) {
    final String normalized = PeerShareCodec.normalizeAddress(address);
    return _liveDevice(normalized) != null ||
        friendAddresses().any(
          (String f) => PeerShareCodec.normalizeAddress(f) == normalized,
        );
  }

  /// Friends whose account is known, and every live device of this account
  /// and of friends.
  Iterable<String> _knownFriends() => <String>{
    ...friendAddresses()
        .where(
          (String f) =>
              _accounts.containsKey(PeerShareCodec.normalizeAddress(f)),
        )
        .map(PeerShareCodec.normalizeAddress),
    ..._liveDeviceAddresses(),
  };

  // ---- "met in person" ----

  /// Accounts [ofAccount] (default: this one) attested as met in person
  /// (none until the ledger is loaded).
  Set<String> metAccounts({String? ofAccount}) => _ready
      ? metAccountsIn(entriesOf(spaceKind: 'acts', ofAccount: ofAccount))
      : <String>{};

  /// Accounts met in person by this account or by a friend (signed
  /// attestations in their `acts`): who counts as verified.
  Set<String> metByCircle() => <String>{
    ...metAccounts(),
    for (final String friend in _accounts.values.toSet())
      ...metAccounts(ofAccount: friend),
  };

  /// Whether this account attested [address] as met in person (or will,
  /// once their account is known).
  bool hasMet(String address) {
    final String normalized = PeerShareCodec.normalizeAddress(address);
    if (_metPending.containsKey(normalized)) {
      return true;
    }
    final String? acc = accountOfAddress(normalized);
    return acc != null && metAccounts().contains(acc);
  }

  /// Addresses of the accounts this account attested as met in person.
  List<String> metAddresses() => <String>[
    for (final String acc in metAccounts()) ...addressesOfAccount(acc),
  ];

  /// The person confirmed meeting [address] in person just now
  /// („Poznaliśmy się osobiście?” after a QR, "W pobliżu" or an event; never
  /// on its own, e.g. from Bluetooth): signs the attestation into `acts`,
  /// where friends get it. Waits for the account when it is not known yet
  /// (a friend request on its way).
  Future<void> attestMet(String address) async {
    await start();
    final String normalized = PeerShareCodec.normalizeAddress(address);
    if (normalized.isEmpty || normalized == _ownAddress) {
      return;
    }
    final String? acc = accountOfAddress(normalized);
    if (acc != null) {
      await _attest(acc, _clock.wallMillis());
      return;
    }
    _metPending.putIfAbsent(normalized, _clock.wallMillis);
    while (_metPending.length > _maxMetPending) {
      _metPending.remove(_metPending.keys.first);
    }
    await _saveMetPending();
  }

  Future<void> _attestPending(String normalized, String acc) async {
    final int? at = _metPending.remove(normalized);
    await _saveMetPending();
    if (at != null && _clock.wallMillis() - at <= _metPendingMs) {
      await _attest(acc, at);
    }
  }

  Future<void> _attest(String acc, int at) async {
    if (acc == account || metAccounts().contains(acc)) {
      return;
    }
    await publish(kMetKind, metBody(acc, at), spaceKind: 'acts');
  }

  Future<void> _loadMetPending() async {
    final Uint8List? raw = await disk.read(_metPendingKey);
    if (raw == null) {
      return;
    }
    try {
      final Object? json = jsonDecode(utf8.decode(raw));
      if (json is Map) {
        json.forEach((Object? k, Object? v) {
          if (k is String && v is int) {
            _metPending[k] = v;
          }
        });
      }
    } on FormatException {
      logZenWarning('Lista spotkań osobiście jest uszkodzona.');
    }
  }

  Future<void> _saveMetPending() => disk.write(
    _metPendingKey,
    Uint8List.fromList(utf8.encode(jsonEncode(_metPending))),
  );

  // ---- several devices per account ----

  _DeviceRef? _liveDevice(String normalized) {
    final _DeviceRef? ref = _devices[normalized];
    if (ref == null ||
        store.directory.isRevoked(ref.account, ref.device) ||
        (ref.account != account && !_accounts.containsValue(ref.account))) {
      return null;
    }
    return ref;
  }

  Iterable<String> _liveDeviceAddresses() => _devices.keys.where(
    (String a) => _liveDevice(a) != null && a != _ownAddress,
  );

  /// Addresses device records of this account or friends' claim, not
  /// proven yet (greeted, never routed to).
  Iterable<String> _hintAddresses() => <String>{
    for (final _DeviceHint h in _deviceHints.values)
      if (h.address != _ownAddress &&
          !store.directory.isRevoked(h.account, h.device) &&
          (h.account == account || _accounts.containsValue(h.account)))
        h.address,
  };

  bool _isSeed(String address) =>
      _deviceSeeds.contains(PeerShareCodec.normalizeAddress(address));

  Set<String> get _ownSpaces => <String>{
    for (final String kind in kAccountSpaceKinds) accountSpace(kind, account),
  };

  bool _isSibling(String address) =>
      _liveDevice(PeerShareCodec.normalizeAddress(address))?.account == account;

  /// Account of [address]: a friend, a friend's other device, or another
  /// device of this account.
  String? accountOfAddress(String address) {
    final String normalized = PeerShareCodec.normalizeAddress(address);
    return _accounts[normalized] ?? _liveDevice(normalized)?.account;
  }

  /// Every known mesh address of [acc]: its devices and the address it was
  /// added by (never this device's own).
  List<String> addressesOfAccount(String acc) {
    final Set<String> out = <String>{
      for (final MapEntry<String, String> e in _accounts.entries)
        if (e.value == acc) e.key,
      for (final String a in _liveDeviceAddresses())
        if (_devices[a]!.account == acc) a,
    }..remove(_ownAddress);
    return out.toList();
  }

  /// This account's other devices that can be reached.
  List<String> get siblingAddresses => addressesOfAccount(account);

  /// Friends' devices and this account's other devices whose key and mesh
  /// address a signed hello proved, for direct links nearby.
  List<AccountDevice> get linkableDevices => <AccountDevice>[
    for (final String a in _liveDeviceAddresses())
      AccountDevice(
        account: _devices[a]!.account,
        device: _devices[a]!.device,
        name: _devices[a]!.name,
        address: a,
      ),
  ];

  /// [accountOfAddress], or the account of a group member's device learnt
  /// from its hello.
  String? accountOfAnyAddress(String address) {
    final String normalized = PeerShareCodec.normalizeAddress(address);
    final _DeviceRef? s = _strangerDevices[normalized];
    return accountOfAddress(normalized) ??
        (s == null || store.directory.isRevoked(s.account, s.device)
            ? null
            : s.account);
  }

  /// Every known address of [acc], group members' devices included.
  List<String> anyAddressesOf(String acc) => <String>{
    ...addressesOfAccount(acc),
    for (final MapEntry<String, _DeviceRef> e in _strangerDevices.entries)
      if (e.value.account == acc &&
          !store.directory.isRevoked(e.value.account, e.value.device))
        e.key,
  }.toList();

  // ---- what own devices share (chats, removed contacts) ----

  /// Seals [plain] for this account's devices and writes it ([spaceKind]
  /// `own`: never leaves them; `private`: friends keep a copy).
  Future<LogEntry?> publishForOwnDevices(
    String kind,
    Map<String, dynamic> plain, {
    String spaceKind = 'own',
    List<String> blobs = const <String>[],
  }) async {
    await start();
    final Uint8List? key = identity.selfKey;
    if (key == null || _suspended) {
      return null;
    }
    final LogEntry e = await publish(
      kind,
      await sealForSelf(plain, key, account: account),
      spaceKind: spaceKind,
      blobs: blobs,
    );
    _opened[e.id] = plain;
    _ownApplied.add(e.id);
    return e;
  }

  /// Readable entries other own devices wrote for this one that were not
  /// handled yet (see [markOwnApplied]).
  List<LogEntry> pendingOwnEntries() => <LogEntry>[
    for (final String kind in <String>['own', 'private'])
      for (final LogEntry e in store.entries(accountSpace(kind, account)))
        if (_isOwnShare(e) && !_ownApplied.contains(e.id)) e,
  ];

  bool _isOwnShare(LogEntry e) =>
      e.account == account &&
      e.device != identity.deviceKey.id &&
      _opened.containsKey(e.id) &&
      (e.space == accountSpace('own', account) ||
          e.kind == kContactRemovedKind);

  bool isOwnApplied(String id) => _ownApplied.contains(id);

  /// [id] was handled: not offered again after a restart.
  Future<void> markOwnApplied(String id) async {
    if (_ownApplied.add(id)) {
      await disk.write(
        _ownAppliedKey,
        Uint8List.fromList(utf8.encode(jsonEncode(_ownApplied.toList()))),
      );
    }
  }

  Future<void> _loadOwnApplied() async {
    final Uint8List? raw = await disk.read(_ownAppliedKey);
    if (raw == null) {
      return;
    }
    try {
      final Object? json = jsonDecode(utf8.decode(raw));
      if (json is List) {
        _ownApplied.addAll(json.whereType<String>());
      }
    } on FormatException {
      // Starts over: applying twice is harmless.
    }
  }

  /// When [address] (a friend) or [group] was last removed on any device
  /// of this account (HLC millis), from the sealed tombstones.
  Map<String, int> contactRemovals() {
    final Map<String, int> out = <String, int>{};
    for (final LogEntry e in store.entries(accountSpace('private', account))) {
      if (e.kind != kContactRemovedKind) {
        continue;
      }
      final Map<String, dynamic>? body = _opened[e.id];
      final Object? a = body?['a'];
      final Object? g = body?['g'];
      final String? k = a is String
          ? PeerShareCodec.normalizeAddress(a)
          : (g is String ? 'group:$g' : null);
      if (k != null) {
        if ((out[k] ?? 0) < e.hlc.millis) {
          out[k] = e.hlc.millis;
        }
      }
    }
    return out;
  }

  /// HLC millis of the newest friends-and-groups backup (0: none).
  int get latestContactsMillis {
    int newest = 0;
    for (final LogEntry e in store.entries(accountSpace('private', account))) {
      if (e.kind == kContactsKind &&
          _opened.containsKey(e.id) &&
          e.hlc.millis > newest) {
        newest = e.hlc.millis;
      }
    }
    return newest;
  }

  /// Peers asked for a file who are not friends (group members): their
  /// answers are taken — only for files this device wants.
  final Set<String> _askedForBlobs = <String>{};
  static const int _maxAskedForBlobs = 512;

  /// Fetches file [id] from [sources], friends or not (the members of a
  /// group a file was shared in): whoever has its pieces hands them over.
  void fetchBlobFrom(String id, Iterable<String> sources) {
    final List<String> normalized = <String>[
      for (final String s in sources)
        if (PeerShareCodec.normalizeAddress(s).isNotEmpty &&
            PeerShareCodec.normalizeAddress(s) != _ownAddress)
          PeerShareCodec.normalizeAddress(s),
    ];
    for (final String s in normalized) {
      _askedForBlobs
        ..remove(s)
        ..add(s);
    }
    while (_askedForBlobs.length > _maxAskedForBlobs) {
      _askedForBlobs.remove(_askedForBlobs.first);
    }
    replicator.fetchBlob(id, normalized);
  }

  /// Fetches files of [ids] from this account's other devices.
  void fetchFromOwnDevices(Iterable<String> ids) {
    final List<String> sources = siblingAddresses;
    if (sources.isEmpty) {
      return;
    }
    for (final String id in ids) {
      replicator.fetchBlob(id, sources);
    }
  }

  /// Waits until blob [id] is here (fetching it from own devices), up to
  /// [timeout]. Returns whether it is.
  Future<bool> waitForBlob(
    String id, {
    Duration timeout = const Duration(minutes: 30),
  }) async {
    if (blobs.isComplete(id)) {
      return true;
    }
    final Future<String> done = mediaCompleted.firstWhere(
      (String got) => got == id,
    );
    fetchFromOwnDevices(<String>[id]);
    try {
      await done.timeout(timeout);
      return true;
    } on Object {
      return blobs.isComplete(id);
    }
  }

  /// This account's devices (this one first), as certified and not cut
  /// off.
  List<AccountDevice> get ownDevices {
    final List<AccountDevice> out = <AccountDevice>[];
    for (final DeviceCertificate cert in store.directory.devicesOf(account)) {
      if (store.directory.isRevoked(account, cert.device)) {
        continue;
      }
      final bool isThis = cert.device == identity.deviceKey.id;
      String? address = isThis ? _ownAddress : null;
      String name = cert.name;
      for (final MapEntry<String, _DeviceRef> e in _devices.entries) {
        if (e.value.device == cert.device) {
          address ??= e.key;
          if (e.value.name.isNotEmpty) {
            name = e.value.name;
          }
        }
      }
      out.add(
        AccountDevice(
          account: account,
          device: cert.device,
          name: name,
          address: address == null || address.isEmpty ? null : address,
          isThis: isThis,
          issued: cert.issued,
        ),
      );
    }
    out.sort(
      (AccountDevice a, AccountDevice b) =>
          a.isThis ? -1 : (b.isThis ? 1 : a.issued.compareTo(b.issued)),
    );
    return out;
  }

  /// Greets [addresses] until they answer with a certificate (the device
  /// this one was linked from; friends who helped recover the account).
  Future<void> rememberDeviceAddresses(Iterable<String> addresses) async {
    await start();
    bool changed = false;
    for (final String a in addresses) {
      final String n = PeerShareCodec.normalizeAddress(a);
      if (n.isNotEmpty && n != _ownAddress && _deviceSeeds.add(n)) {
        changed = true;
        _hello(n, force: true);
      }
    }
    if (changed) {
      await _saveDevices();
    }
  }

  /// Records [address] as device [device] of [acc] when that account is
  /// this one or a friend's. Only for a device that proved it is there: a
  /// hello sent from [address] and signed by [device] ([_proven]). Returns
  /// whether it is (now) known.
  Future<bool> _learnDevice(
    String address,
    String acc,
    String device,
    String name,
  ) async {
    final String n = PeerShareCodec.normalizeAddress(address);
    if (n.isEmpty ||
        n == _ownAddress ||
        device == identity.deviceKey.id ||
        store.directory.isRevoked(acc, device) ||
        (acc != account && !_accounts.containsValue(acc))) {
      return false;
    }
    // Its newest record named this address: that claim is proven now.
    final _DeviceHint? hint = _deviceHints[device];
    final _DeviceHint? claim =
        hint != null && hint.account == acc && hint.address == n ? hint : null;
    final _DeviceRef? had = _devices[n];
    if (claim == null &&
        had != null &&
        had.account == acc &&
        had.device == device) {
      return true;
    }
    _devices[n] = claim != null
        ? _DeviceRef(
            acc,
            device,
            claim.name.isEmpty ? name : claim.name,
            claim.at,
          )
        : _DeviceRef(acc, device, name, 0);
    if (claim != null) {
      _deviceHints.remove(device);
      // It moved there: the addresses it had before are stale.
      _devices.removeWhere(
        (String a, _DeviceRef r) => r.device == device && a != n,
      );
    }
    _deviceSeeds.remove(n);
    await _saveDevices();
    _emitDevices();
    return true;
  }

  /// A device record (`{address, name}` in an account's `acts`) is only a
  /// claim: the account signed it, not whoever is at that address, so a
  /// friend could name anyone's address. It is kept as a hint and the
  /// address greeted; the device is known (and routed to) only once a
  /// hello from there proves its key ([_learnDevice]). A record only
  /// renames a device already proven at that address.
  Future<void> _onDeviceRecord(LogEntry e, {bool quiet = false}) async {
    if (e.kind != kDeviceRecordKind ||
        e.space != accountSpace('acts', e.account) ||
        e.device == identity.deviceKey.id ||
        store.directory.isRevoked(e.account, e.device) ||
        (e.account != account && !_accounts.containsValue(e.account))) {
      return;
    }
    final Object? raw = e.body['address'];
    if (raw is! String || !isRoutablePeerAddress(raw)) {
      return;
    }
    final String n = PeerShareCodec.normalizeAddress(raw);
    if (n == _ownAddress) {
      return;
    }
    // The device key it names: signed (hybrid) by the device, in a space of
    // this account or a friend's. Pinned before any contact; a different
    // pin already there stays and is reported.
    final Object? pq = e.body['pq'];
    if (pq is String && _sessionKeyPattern.hasMatch(pq)) {
      _rememberSessionKey(n, pq);
      onSessionKeys?.call(<String, String>{n: pq});
    }
    // Only the newest record of a device counts (it may have moved).
    for (final _DeviceRef r in _devices.values) {
      if (r.device == e.device && r.at > e.hlc.millis) {
        return;
      }
    }
    final _DeviceHint? pending = _deviceHints[e.device];
    if (pending != null && pending.at >= e.hlc.millis) {
      return;
    }
    final Object? rawName = e.body['name'];
    final String name = rawName is String ? rawName : '';
    final _DeviceRef? had = _devices[n];
    if (had != null && had.account == e.account && had.device == e.device) {
      if (had.at >= e.hlc.millis) {
        return;
      }
      // Proven to be at this address already: only the name changes (and
      // whatever address it claimed before is stale).
      _deviceHints.remove(e.device);
      _devices[n] = _DeviceRef(e.account, e.device, name, e.hlc.millis);
      _devices.removeWhere(
        (String a, _DeviceRef r) => r.device == e.device && a != n,
      );
      await _saveDevices();
      _emitDevices();
      return;
    }
    // Anything else waits for the proof; an entry of another device or
    // account at that address stays as it is.
    _deviceHints[e.device] = _DeviceHint(
      e.account,
      e.device,
      name,
      e.hlc.millis,
      n,
    );
    _capHints(e.account);
    // Its proven hello may be here already (sent before its account was a
    // friend's, e.g. as a group member): enough now.
    final _DeviceRef? seen = _strangerDevices[n];
    if (seen != null &&
        seen.account == e.account &&
        seen.device == e.device &&
        await _learnDevice(n, seen.account, seen.device, seen.name)) {
      return;
    }
    if (!quiet) {
      _hello(n, force: true);
    }
  }

  /// At most [_maxHintsPerAccount] unproven devices of [acc] (the oldest
  /// claims go): an account can certify any number of devices, and each
  /// claim is greeted.
  void _capHints(String acc) {
    final List<_DeviceHint> its = <_DeviceHint>[
      for (final _DeviceHint h in _deviceHints.values)
        if (h.account == acc) h,
    ];
    if (its.length <= _maxHintsPerAccount) {
      return;
    }
    its.sort((_DeviceHint x, _DeviceHint y) => x.at.compareTo(y.at));
    for (final _DeviceHint h in its.take(its.length - _maxHintsPerAccount)) {
      _deviceHints.remove(h.device);
    }
  }

  /// Says (in this account's `acts`) at which address this device is,
  /// when that changed.
  Future<void> publishOwnDevice() async {
    await start();
    await _publishOwnDevice();
  }

  Future<void> _publishOwnDevice() async {
    final String address = _ownAddress;
    if (address.isEmpty || _suspended || _stopped) {
      return;
    }
    LogEntry? last;
    for (final LogEntry e in store.entries(accountSpace('acts', account))) {
      if (e.kind == kDeviceRecordKind &&
          e.device == identity.deviceKey.id &&
          (last == null || e.hlc > last.hlc)) {
        last = e;
      }
    }
    final String key = _ownSessionKey;
    if (last != null &&
        last.body['address'] == address &&
        last.body['name'] == deviceName &&
        (key.isEmpty || last.body['pq'] == key)) {
      return;
    }
    // Not [publish]: this also runs while starting. The post-quantum
    // device key goes along: friends pin it before they ever talk here.
    await author.append(
      accountSpace('acts', account),
      kDeviceRecordKind,
      <String, dynamic>{
        'address': address,
        'name': deviceName,
        if (key.isNotEmpty) 'pq': key,
      },
    );
  }

  /// Cuts [device] of this account off (a lost or stolen phone): what it
  /// wrote so far stays, anything later is refused everywhere, and it
  /// no longer gets messages. Needs the account key ([LedgerIdentity.unlock]
  /// with the account password first, if one is set).
  Future<void> unlinkDevice(String device) async {
    await start();
    final LedgerKeyPair? key = identity.accountKey;
    if (key == null) {
      throw StateError(t('Najpierw odblokuj konto hasłem konta.'));
    }
    if (device == identity.deviceKey.id) {
      throw StateError(t('Tego urządzenia nie można odłączyć z niego samego.'));
    }
    final DeviceRevocation revocation = await DeviceRevocation.issue(
      account: key,
      device: device,
      cutoffs: store.headsOfDevice(account: account, device: device),
      issued: _clock.wallMillis(),
    );
    final _DeviceHint? claimed = _deviceHints.remove(device);
    final Set<String> itsAddresses = <String>{
      for (final MapEntry<String, _DeviceRef> e in _devices.entries)
        if (e.value.device == device) e.key,
      if (claimed != null) claimed.address,
    };
    await replicator.publishRevocation(revocation);
    _devices.removeWhere((_, _DeviceRef r) => r.device == device);
    await _saveDevices();
    _emitDevices();
    // Friends who never heard of this device still get the news through
    // everyone else; the device itself is told too, so it stops.
    for (final String a in itsAddresses) {
      _send(a, <String, dynamic>{
        'type': LedgerMessages.revoke,
        'items': <Map<String, dynamic>>[revocation.toJson()],
      });
    }
  }

  /// Whether this device was cut off by another device of the account.
  bool get isRevoked =>
      store.directory.isRevoked(account, identity.deviceKey.id);

  void _pruneRevoked() {
    _deviceHints.removeWhere(
      (_, _DeviceHint h) => store.directory.isRevoked(h.account, h.device),
    );
    final int before = _devices.length;
    _devices.removeWhere(
      (_, _DeviceRef r) => store.directory.isRevoked(r.account, r.device),
    );
    if (_devices.length != before) {
      unawaitedLogged(_saveDevices(), context: 'Zapis urządzeń konta');
      _emitDevices();
    }
  }

  void _emitDevices() {
    if (!_devicesChanged.isClosed) {
      _devicesChanged.add(null);
    }
  }

  Future<void> _saveDevices() => disk.write(
    _devicesKey,
    Uint8List.fromList(
      utf8.encode(
        jsonEncode(<String, dynamic>{
          'devices': <String, dynamic>{
            for (final MapEntry<String, _DeviceRef> e in _devices.entries)
              e.key: e.value.toJson(),
          },
          'seeds': _deviceSeeds.toList(),
        }),
      ),
    ),
  );

  Future<void> _loadDevices() async {
    final Uint8List? raw = await disk.read(_devicesKey);
    if (raw == null) {
      return;
    }
    try {
      final Object? json = jsonDecode(utf8.decode(raw));
      if (json is! Map) {
        return;
      }
      final Object? devices = json['devices'];
      if (devices is Map) {
        devices.forEach((Object? k, Object? v) {
          if (k is String && v is Map) {
            final Object? a = v['a'];
            final Object? d = v['d'];
            final Object? n = v['n'];
            final Object? t = v['t'];
            if (a is String && d is String) {
              final String name = n is String ? n : '';
              final int at = t is int ? t : 0;
              _devices[k] = _DeviceRef(a, d, name, at);
            }
          }
        });
      }
      final Object? seeds = json['seeds'];
      if (seeds is List) {
        _deviceSeeds.addAll(seeds.whereType<String>());
      }
    } on FormatException {
      logZenWarning('Lista urządzeń konta jest uszkodzona; zaczynam od zera.');
    }
  }

  /// The newest backup of friends and groups any device of this account
  /// saved, or `null`.
  Map<String, dynamic>? latestContacts() {
    LogEntry? newest;
    for (final LogEntry e in store.entries(accountSpace('private', account))) {
      if (e.kind == kContactsKind &&
          _opened.containsKey(e.id) &&
          (newest == null || e.hlc > newest.hlc)) {
        newest = e;
      }
    }
    return newest == null ? null : _opened[newest.id];
  }

  /// Saves [snapshot] (friends and groups) sealed for this account's own
  /// devices, unless it equals the newest one. Returns whether it did.
  Future<bool> publishContacts(Map<String, dynamic> snapshot) async {
    await start();
    final Uint8List? key = identity.selfKey;
    if (key == null || _suspended) {
      return false;
    }
    final Map<String, dynamic>? latest = latestContacts();
    if (latest != null && jsonEncode(latest) == jsonEncode(snapshot)) {
      return false;
    }
    final LogEntry e = await publish(
      kContactsKind,
      await sealForSelf(snapshot, key, account: account),
      spaceKind: 'private',
    );
    _opened[e.id] = snapshot;
    return true;
  }

  void _sendSiblingSync(String to, {bool answer = false}) {
    if (!_isSibling(to)) {
      return;
    }
    _send(to, <String, dynamic>{
      'type': kLedgerSiblingType,
      if (answer) 'ack': true,
      'own': keyring.toJson()['own'],
      'levels': <String, String>{
        for (final MapEntry<String, FriendLevel> e in _levels.entries)
          e.key: e.value.name,
      },
    });
  }

  Future<void> _onSiblingSync(String from, Map<String, dynamic> m) async {
    if (!_isSibling(from)) {
      return;
    }
    // Ours may have reached them before they could prove who we are (and
    // been dropped): answer once with our own, never an answer to an answer.
    if (m['ack'] != true) {
      _sendSiblingSync(from, answer: true);
    }
    final int added = keyring.mergeOwn(m['own']);
    bool levels = false;
    final Object? theirs = m['levels'];
    if (theirs is Map) {
      theirs.forEach((Object? k, Object? v) {
        final FriendLevel? level = friendLevelByName(v);
        if (k is String && level != null && !_levels.containsKey(k)) {
          _levels[k] = level;
          levels = true;
        }
      });
    }
    if (added > 0) {
      await _saveKeyring();
      await _open(_sealedEntries(ofAccount: account));
      // Friends may read what the other device wrote with these.
      _sendKeysToAll();
    }
    if (levels) {
      await _saveLevels();
    }
  }

  void _send(String peer, Map<String, dynamic> message) {
    if (_stopped) {
      return;
    }
    unawaitedLogged(
      transport.send(remoteAddress: peer, payload: message),
      context: 'Wysłanie wiadomości dziennika nie udało się',
    );
  }

  void _hello(String friend, {bool force = false, bool reply = false}) {
    final String normalized = PeerShareCodec.normalizeAddress(friend);
    final int now = _clock.wallMillis();
    final int? last = _helloSentAt[normalized];
    // Never more than one unforced hello a second, whatever the interval:
    // any frame from a friend triggers one, so a zero interval would make
    // two friends greet each other forever.
    final int gap = helloInterval.inMilliseconds < 1000
        ? 1000
        : helloInterval.inMilliseconds;
    if (!force && last != null && now - last < gap) {
      return;
    }
    _helloSentAt[normalized] = now;
    final String me = _ownAddress;
    unawaitedLogged(() async {
      // Proves the device key holder is at this address (the certificate
      // alone is public and could be shown by anyone).
      // ... and holds the post-quantum device key that seals this frame.
      final String key = _ownSessionKey;
      final Uint8List proof = await identity.deviceKey.sign(
        _proofBytes(me, key),
      );
      _send(friend, <String, dynamic>{
        ...?helloExtras?.call(normalized),
        if (_isFriend(friend)) 'caps': kZenCaps,
        'type': kLedgerHelloType,
        'cert': identity.certificate.toJson(),
        'p': <String, dynamic>{
          'f': me,
          if (key.isNotEmpty) 'k': key,
          's': b64(proof),
        },
        if (reply) 'r': 1,
      });
    }(), context: 'Powitanie dziennika nie wyszło');
  }

  /// What a hello's proof signs: the address and the post-quantum device
  /// key fingerprint ('' when the node does not know it).
  static Uint8List _proofBytes(String from, String sessionKey) =>
      Uint8List.fromList(utf8.encode('zen.hello.v2|$from|$sessionKey'));

  static final RegExp _sessionKeyPattern = RegExp(r'^[0-9a-f]{64}$');

  String get _ownSessionKey {
    final String key = (localSessionKey?.call() ?? '').toLowerCase();
    return _sessionKeyPattern.hasMatch(key) ? key : '';
  }

  /// Whether a hello really comes from the device in [cert]: signed by its
  /// device key for the address it came from and for the post-quantum
  /// device key whose session carried it ([SignalTransportFrame.senderKey]).
  /// A signed key that is not the session's means someone else holds the
  /// address's node key: refused, the signed key pinned when the hello is
  /// of the account known at that address, and the app warned.
  Future<bool> _proven(
    SignalTransportFrame frame,
    DeviceCertificate cert,
  ) async {
    final Object? p = frame.payload['p'];
    if (p is! Map) {
      return false;
    }
    final Object? f = p['f'];
    final Object? s = p['s'];
    final Object? k = p['k'];
    final String key = k is String ? k : '';
    if (f is! String ||
        s is! String ||
        f.isEmpty ||
        (key.isNotEmpty && !_sessionKeyPattern.hasMatch(key)) ||
        PeerShareCodec.normalizeAddress(f) !=
            PeerShareCodec.normalizeAddress(frame.from)) {
      return false;
    }
    if (!await cert.verifyByDevice(_proofBytes(f, key), s)) {
      return false;
    }
    final String address = PeerShareCodec.normalizeAddress(frame.from);
    final String? session = frame.senderKey?.toLowerCase();
    if (session != null && session != key) {
      if (key.isNotEmpty) {
        _sessionKeyMismatch(address, cert, key);
      }
      return false;
    }
    if (key.isNotEmpty) {
      _rememberSessionKey(address, key);
      onSessionKeys?.call(<String, String>{address: key});
    }
    return true;
  }

  void _rememberSessionKey(String address, String key) {
    if (!_sessionKeys.containsKey(address) &&
        _sessionKeys.length >= _maxSessionKeys) {
      _sessionKeys.remove(_sessionKeys.keys.first);
    }
    _sessionKeys[address] = key;
  }

  void _sessionKeyMismatch(
    String address,
    DeviceCertificate cert,
    String signedKey,
  ) {
    logZenWarning(
      'Dziennik: klucz urządzenia pod $address nie zgadza się z sesją.',
    );
    // The device signed its key: when it is the device (or account) this
    // node knows there, that key is the one to trust, and the session that
    // carried the hello is someone else's.
    final _DeviceRef? device = _liveDevice(address);
    final bool known =
        _accounts[address] == cert.account ||
        (device != null && device.device == cert.device) ||
        cert.account == account;
    if (known) {
      _rememberSessionKey(address, signedKey);
      onSessionKeys?.call(<String, String>{address: signedKey}, force: true);
    }
    final int now = _clock.wallMillis();
    final int? warned = _keyWarnedAt[address];
    if (warned == null || now - warned >= 3600 * 1000) {
      _keyWarnedAt[address] = now;
      onDeviceKeyMismatch?.call(address);
    }
  }

  void _subscribePublic(String acc) {
    for (final String kind in kPublicSpaceKinds) {
      replicator.subscribe(accountSpace(kind, acc));
    }
  }

  Set<String> _followedSpaces(String peer) {
    final String? acc = _followed[PeerShareCodec.normalizeAddress(peer)];
    if (acc == null || acc.isEmpty) {
      return const <String>{};
    }
    return <String>{
      for (final String kind in kPublicSpaceKinds) accountSpace(kind, acc),
    };
  }

  Set<String> get _ownPublicSpaces => <String>{
    for (final String kind in kPublicSpaceKinds) accountSpace(kind, account),
  };

  bool _strangerAllowed(String address) {
    final int minute = _clock.wallMillis() ~/ 60000;
    final int total = _strangerTotal.$1 == minute ? _strangerTotal.$2 : 0;
    if (total >= kStrangerFramesPerMinuteTotal) {
      return false;
    }
    final String network = _network64(address);
    final (int, int)? had = _strangerBudget[network];
    final int used = had == null || had.$1 != minute ? 0 : had.$2;
    if (used >= kStrangerFramesPerMinute) {
      return false;
    }
    if (had == null && _strangerBudget.length >= _maxStrangerNetworks) {
      // Forget earlier minutes. Never everything at once: that would hand
      // every flooding address a fresh budget.
      _strangerBudget.removeWhere(
        (String _, (int, int) budget) => budget.$1 != minute,
      );
      if (_strangerBudget.length >= _maxStrangerNetworks) {
        return false;
      }
    }
    _strangerBudget[network] = (minute, used + 1);
    _strangerTotal = (minute, total + 1);
    return true;
  }

  /// The /64 network of a mesh address (the address itself if unparsable).
  static String _network64(String address) {
    try {
      return Uri.parseIPv6Address(
        PeerShareCodec.normalizeAddress(address),
      ).take(8).map((int b) => b.toRadixString(16).padLeft(2, '0')).join();
    } on FormatException {
      return address;
    }
  }

  /// Checks a certificate a stranger sent. Anyone can mint accounts, so
  /// only certificates of accounts this device has a reason to know (its
  /// own, friends', followed ones) go into the directory; the rest are only
  /// verified, never stored.
  Future<bool> _checkStrangerCertificate(DeviceCertificate cert) async {
    if (cert.account == account ||
        _accounts.containsValue(cert.account) ||
        _followed.containsValue(cert.account)) {
      return store.directory.addCertificate(cert);
    }
    return store.directory.knowsCertificate(cert) || await cert.verify();
  }

  /// A stranger (not a friend) may: say hello, and read this account's
  /// public spaces. A followed account may also send its public entries.
  Future<void> _onStrangerFrame(SignalTransportFrame frame) async {
    final String from = PeerShareCodec.normalizeAddress(frame.from);
    final Object? type = frame.payload['type'];
    if (type != kLedgerHelloType && !isLedgerMessage(frame.payload)) {
      return;
    }
    if (!_strangerAllowed(from)) {
      return;
    }
    if (type == kLedgerHelloType) {
      final DeviceCertificate? cert = DeviceCertificate.fromJson(
        frame.payload['cert'],
      );
      if (cert == null || !await _checkStrangerCertificate(cert)) {
        return;
      }
      final bool proven = await _proven(frame, cert);
      // Another device of a friend or of this account (its certificate,
      // signed by the account key, and the device key's proof for this
      // address): from now on a friend.
      if (proven &&
          await _learnDevice(from, cert.account, cert.device, cert.name)) {
        // Prove ourselves to them first: what _onHello sends next (own
        // keys to a sibling) is only accepted from a proven device.
        if (frame.payload['r'] != 1) {
          _hello(from, force: true, reply: true);
        }
        await _onHello(from, frame);
        return;
      }
      if (proven &&
          !store.directory.isRevoked(cert.account, cert.device) &&
          cert.account != account) {
        // Someone else (a group member): remember whose device it is.
        if (_strangerDevices.length >= _maxStrangerDevices) {
          _strangerDevices.remove(_strangerDevices.keys.first);
        }
        _strangerDevices[from] = _DeviceRef(
          cert.account,
          cert.device,
          cert.name,
          0,
        );
        onStrangerHello?.call(from, cert.account, frame.payload);
      }
      if (_isSeed(from)) {
        // Not vouched for (yet): it may hold our own entries (a friend
        // keeping our backup while we recover). Ask for those only.
        replicator.syncWith(from, only: _ownSpaces);
      }
      final String? known = _followed[from];
      if (known != null) {
        if (known != cert.account) {
          _followed[from] = cert.account;
          _subscribePublic(cert.account);
          await _saveFollowing();
        }
        replicator.syncWith(from, only: _followedSpaces(from));
      }
      // Someone following us: answer (once, never to an answer) so they
      // learn our account.
      if (frame.payload['r'] != 1) {
        _hello(from, force: true, reply: true);
      }
      return;
    }
    final Set<String> readable = <String>{
      ..._ownPublicSpaces,
      ..._followedSpaces(from),
      // A seed may hand our own entries back; nothing private is served.
      if (_isSeed(from) && type == LedgerMessages.heads) ..._ownSpaces,
    };
    if (type == LedgerMessages.heads) {
      final Object? spaces = frame.payload['spaces'];
      if (spaces is! Map) {
        return;
      }
      await replicator.handle(from, <String, dynamic>{
        'type': LedgerMessages.heads,
        'spaces': <String, dynamic>{
          for (final MapEntry<dynamic, dynamic> e in spaces.entries)
            if (readable.contains(e.key)) e.key as String: e.value,
        },
      });
      return;
    }
    if (type == LedgerMessages.want) {
      if (readable.contains(frame.payload['space'])) {
        await replicator.handle(from, frame.payload);
      }
      return;
    }
    if ((type == LedgerMessages.entries || type == LedgerMessages.certs) &&
        (_followedSpaces(from).isNotEmpty || _isSeed(from))) {
      await replicator.handle(from, frame.payload);
      return;
    }
    if (type == LedgerMessages.certWant) {
      // Certificates of the devices whose entries a stranger may read.
      replicator.answerCertificates(
        from,
        frame.payload['items'],
        inSpace: readable.contains,
      );
      return;
    }
    if (type == LedgerMessages.blobWant) {
      final Object? chunks = frame.payload['chunks'];
      await replicator.handle(from, <String, dynamic>{
        ...frame.payload,
        'chunks': chunks is List
            ? chunks.take(strangerChunksPerRequest).toList()
            : const <Object?>[],
      });
      return;
    }
    // Answers to what we asked a followed account for (only wanted blobs
    // are taken).
    if ((type == LedgerMessages.blobManifest ||
            type == LedgerMessages.blobChunk) &&
        (_followedSpaces(from).isNotEmpty || _askedForBlobs.contains(from))) {
      await replicator.handle(from, frame.payload);
    }
  }

  /// Downloads the media of [e] now (when automatic download is off),
  /// including files its later edits put in.
  void downloadMedia(LogEntry e) {
    _fetchMediaOf(e);
    for (final LogEntry edit in store.entries(e.space)) {
      if (edit.kind == 'post_edit' &&
          edit.account == e.account &&
          bodyOf(edit)?['post'] == e.id) {
        _fetchMediaOf(edit);
      }
    }
  }

  /// Photos and videos of what we hold that are still missing (the author
  /// was offline, the app was closed mid-download): asked for again from
  /// the author and every friend — whoever has them now.
  void _resumeMedia() {
    bool? auto;
    for (final String space in replicator.subscriptions.toList()) {
      for (final LogEntry e in store.entries(space)) {
        if (e.account == account) {
          continue;
        }
        final List<String> ids = _mediaIdsOf(e);
        if (!ids.any(
          (String id) =>
              !blobs.isComplete(id) && !blobs.refusedFor(id, e.account),
        )) {
          continue;
        }
        // The setting is read only when something is actually missing.
        if (!(auto ??= autoDownloadMedia())) {
          return;
        }
        _fetchMediaOf(e);
      }
    }
  }

  /// Blob ids of [e]: its own, or those of the post a reshare carries.
  static List<String> _mediaIdsOf(LogEntry e) {
    final Object? inner = e.body['entry'];
    final Object? blobs = inner is Map ? inner['blobs'] : null;
    return <String>[
      ...e.blobs,
      if (blobs is List)
        for (final Object? b in blobs.take(16))
          if (b is String) b,
    ];
  }

  /// Starts downloading the media of [e] from whoever can have them: the
  /// writer's addresses first, then all friends.
  void _fetchMediaOf(LogEntry e) {
    final List<String> ids = _mediaIdsOf(e);
    if (ids.isEmpty) {
      return;
    }
    final List<String> sources = <String>[
      for (final MapEntry<String, String> m in <MapEntry<String, String>>[
        ..._accounts.entries,
        ..._followed.entries,
      ])
        if (m.value == e.account) m.key,
      ..._knownFriends(),
    ];
    for (final String id in ids) {
      if (e.account != account) {
        // Remembered as brought by this writer: only their removal (or
        // the storage limits) may drop it later, never someone else
        // naming it.
        blobs
          ..allowFor(id, e.account)
          ..noteFetchFor(id, e.account);
      }
      replicator.fetchBlob(id, sources.toSet().toList());
    }
  }

  void _followAccount(String friendAccount) {
    for (final String kind in kFollowedFriendSpaces) {
      replicator.subscribe(accountSpace(kind, friendAccount));
    }
  }

  Future<void> _onFrame(SignalTransportFrame frame) async {
    if (!_isFriend(frame.from)) {
      await _onStrangerFrame(frame);
      return;
    }
    // Any sign of life from a friend (a chat message, a call…) is a chance
    // to catch up: the hello (at most every [helloInterval]) makes them
    // sync with us.
    _hello(frame.from);
    final Object? type = frame.payload['type'];
    if (type == kLedgerPushType) {
      await replicator.handle(frame.from, <String, dynamic>{
        'type': LedgerMessages.entries,
        'entries': frame.payload['entries'],
      });
      return;
    }
    if (type != kLedgerHelloType &&
        type != kLedgerBridgesType &&
        type != kLedgerReachType &&
        type != kLedgerReachOkType &&
        type != kLedgerSiblingType &&
        type != kLedgerKeysType &&
        !isLedgerMessage(frame.payload)) {
      return;
    }
    if (type == kLedgerKeysType) {
      await _onKeys(frame.from, frame.payload['items']);
      return;
    }
    if (type == kLedgerHelloType) {
      await _onHello(frame.from, frame);
      return;
    }
    if (type == kLedgerBridgesType) {
      await _onBridges(frame.payload['items']);
      return;
    }
    if (type == kLedgerReachType) {
      await _onReachRequest(frame.from, frame.payload);
      return;
    }
    if (type == kLedgerSiblingType) {
      await _onSiblingSync(frame.from, frame.payload);
      return;
    }
    if (type == kLedgerReachOkType) {
      _onReachAnswer(frame.from, frame.payload);
      return;
    }
    await replicator.handle(frame.from, frame.payload);
  }

  Future<void> _onHello(String from, SignalTransportFrame frame) async {
    final DeviceCertificate? cert = DeviceCertificate.fromJson(
      frame.payload['cert'],
    );
    if (cert == null || !await store.directory.addCertificate(cert)) {
      return;
    }
    // Which account an address belongs to is only taken from a proven
    // hello (where this device does not know its own address yet — tests
    // without a mesh — the certificate alone).
    final bool proven = await _proven(frame, cert);
    if (_ownAddress.isNotEmpty && !proven) {
      return;
    }
    final String normalized = PeerShareCodec.normalizeAddress(from);
    final _DeviceRef? device = _liveDevice(normalized);
    if (device != null) {
      // Another device of a friend, or of this account: its account is
      // what its certificate says, nothing to remember per address.
      if (device.account != cert.account) {
        return;
      }
    } else {
      final bool isNew = _accounts[normalized] != cert.account;
      _accounts[normalized] = cert.account;
      if (isNew) {
        await _savePeers();
        // Make sure they learn about us too, then catch up both ways.
        _hello(from, force: true);
      }
    }
    // The device its record put here answered from here: proven now.
    if (proven && _deviceHints[cert.device]?.address == normalized) {
      await _learnDevice(normalized, cert.account, cert.device, cert.name);
    }
    if (cert.account != account) {
      _followAccount(cert.account);
    }
    if (_metPending.containsKey(normalized)) {
      await _attestPending(normalized, cert.account);
    }
    replicator.syncWith(
      from,
      extra: <String>[
        for (final String s in store.spaces)
          if (_forwardsUnknown(from, s)) s,
      ],
    );
    // They may hold photos or videos we could not get yet.
    replicator.offerSource(normalized);
    if (!_peerGreeted.isClosed) {
      _peerGreeted.add(normalized);
    }
    _shareBridges(from);
    _sendKeys(from);
    _sendSiblingSync(from);
  }

  void _sendKeys(String friend) {
    if (!_isFriend(friend) || _isSibling(friend)) {
      return;
    }
    final List<AudienceKey> keys = keyring.entitled(levelOf(friend));
    if (keys.isEmpty) {
      return;
    }
    _send(friend, <String, dynamic>{
      'type': kLedgerKeysType,
      'items': <Map<String, dynamic>>[
        for (final AudienceKey k in keys) k.toJson(),
      ],
    });
  }

  void _sendKeysToAll() {
    for (final String friend in _knownFriends()) {
      _sendKeys(friend);
    }
  }

  Future<void> _onKeys(String from, Object? items) async {
    final String? acc = accountOfAddress(from);
    if (acc == null || acc == account) {
      return;
    }
    if (keyring.acceptFrom(acc, items) > 0) {
      await _saveKeyring();
      await _open(_sealedEntries(ofAccount: acc));
    }
  }

  Iterable<LogEntry> _sealedEntries({String? ofAccount}) sync* {
    for (final String space in store.spaces.toList()) {
      for (final LogEntry e in store.entries(space)) {
        if ((ofAccount == null || e.account == ofAccount) &&
            isSealed(e.body) &&
            !_opened.containsKey(e.id)) {
          yield e;
        }
      }
    }
  }

  Future<void> _open(Iterable<LogEntry> entries) async {
    bool any = false;
    for (final LogEntry e in entries.toList()) {
      if (_opened.containsKey(e.id)) {
        continue;
      }
      final Uint8List? selfKey = identity.selfKey;
      final Map<String, dynamic>? plain = e.body['kid'] == kSelfKeyId
          ? (e.account == account && selfKey != null
                ? await openForSelf(e.body, selfKey, account: account)
                : null)
          : await openBody(e.body, keyring, account: e.account, self: account);
      if (plain != null) {
        _opened[e.id] = plain;
        any = true;
        if (e.kind == kContactsKind &&
            e.device != identity.deviceKey.id &&
            !_contactsChanged.isClosed) {
          _contactsChanged.add(null);
        }
        if (_isOwnShare(e) &&
            !_ownApplied.contains(e.id) &&
            !_ownEntries.isClosed) {
          _ownEntries.add(e);
        }
      }
    }
    if (any && !_openedChanges.isClosed) {
      _openedChanges.add(null);
    }
  }

  Future<void> _loadKeys() async {
    final Uint8List? raw = await disk.read(_keyringKey);
    if (raw != null) {
      try {
        final Object? json = jsonDecode(utf8.decode(raw));
        // A newer build's keys stay as they are (saves are skipped).
        heldAsNewerOn(disk, _keyringKey, json, current: 1);
        keyring.restore(json);
      } on FormatException {
        logZenWarning('Klucze odbiorców są uszkodzone.');
      }
    }
    if (keyring.ensureOwn(_clock.wallMillis())) {
      await _saveKeyring();
    }
    final Uint8List? levels = await disk.read(_levelsKey);
    if (levels != null) {
      try {
        final Object? json = jsonDecode(utf8.decode(levels));
        if (json is Map) {
          json.forEach((Object? k, Object? v) {
            final FriendLevel? level = friendLevelByName(v);
            if (k is String && level != null) {
              _levels[k] = level;
            }
          });
        }
      } on FormatException {
        logZenWarning('Poziomy znajomych są uszkodzone.');
      }
    }
  }

  Future<void> _saveKeyring() => disk.write(
    _keyringKey,
    Uint8List.fromList(utf8.encode(jsonEncode(keyring.toJson()))),
  );

  Future<void> _saveLevels() => disk.write(
    _levelsKey,
    Uint8List.fromList(
      utf8.encode(
        jsonEncode(<String, String>{
          for (final MapEntry<String, FriendLevel> e in _levels.entries)
            e.key: e.value.name,
        }),
      ),
    ),
  );

  void _shareBridges(String friend) {
    final List<Map<String, dynamic>> items = bridges.sample(50);
    if (items.isNotEmpty) {
      _send(friend, <String, dynamic>{
        'type': kLedgerBridgesType,
        'items': items,
      });
    }
  }

  Future<void> _onBridges(Object? items) async {
    if (items is! List) {
      return;
    }
    final int added = await bridges.addAll(items);
    final int probed = await bridges.probeSome();
    if (added > 0 || probed > 0) {
      await _saveBridges();
      _publishChoice();
    }
  }

  /// Re-checks known bridges now and then (dead ones go, slow ones drop
  /// down the list) and reconnects if the best choice changed.
  Future<void> maintainBridges() async {
    if (_suspended || _stopped) {
      return;
    }
    if (await bridges.probeSome() > 0) {
      await _saveBridges();
    }
    _publishChoice();
  }

  void _publishChoice() {
    final List<String> choice = bridges.choose(bridgeConnections);
    if (choice.isEmpty || listEquals(choice, _chosenBridges)) {
      return;
    }
    _chosenBridges = choice;
    onBridgesChosen?.call(choice);
  }

  /// Announces this device as a mesh entry point at [uri] (a desktop that
  /// accepts incoming connections). Mandatory for every device that can:
  /// without bridges the network depends on a few public nodes.
  Future<BridgeAnnouncement> announceBridge(
    String uri, {
    Duration validity = const Duration(days: 6),
    int powBits = kBridgePowBits,
  }) async {
    await start();
    final LedgerKeyPair key = await _bridgeKey();
    final BridgeAnnouncement announcement = await BridgeAnnouncement.create(
      uri: uri,
      bridgeKey: key,
      expires: _clock.wallMillis() + validity.inMilliseconds,
      powBits: powBits,
    );
    bridges.addOwn(announcement);
    await _saveBridges();
    for (final String friend in _knownFriends()) {
      _shareBridges(friend);
    }
    return announcement;
  }

  /// Stops announcing this device as a bridge (it cannot be reached any
  /// more). Friends drop it once their checks fail.
  Future<void> withdrawBridge() async {
    if (bridges.removeOwn()) {
      await _saveBridges();
    }
  }

  /// This device's current bridge announcement, if any.
  BridgeAnnouncement? get ownBridge => bridges.own?.announcement;

  /// Asks up to [askAtMost] friends to connect to [uri] from where they
  /// are and say whether this computer answered as a mesh node.
  Future<ReachResult> checkReachable(
    String uri, {
    Duration timeout = const Duration(seconds: 20),
    int askAtMost = 5,
  }) async {
    await start();
    final List<String> friends = _knownFriends().toList()..shuffle();
    if (friends.isEmpty || _suspended) {
      return ReachResult.noAnswer;
    }
    final String id = _randomId();
    final _ReachWait wait = _ReachWait(friends.take(askAtMost).toSet());
    _reachWaits[id] = wait;
    for (final String friend in wait.asked) {
      _send(friend, <String, dynamic>{
        'type': kLedgerReachType,
        'id': id,
        'uri': uri,
      });
    }
    try {
      return await wait.done.future.timeout(
        timeout,
        onTimeout: () =>
            wait.noes > 0 ? ReachResult.unreachable : ReachResult.noAnswer,
      );
    } finally {
      _reachWaits.remove(id);
    }
  }

  Future<void> _onReachRequest(String from, Map<String, dynamic> m) async {
    final Object? id = m['id'];
    final Object? uri = m['uri'];
    if (id is! String || id.length > 64 || uri is! String || uri.length > 300) {
      return;
    }
    final int now = _clock.wallMillis();
    _reachAnsweredAt.removeWhere((int t) => now - t > 60000);
    if (_reachAnsweredAt.length >= kReachChecksPerMinute) {
      return; // nobody gets to use us as a port scanner
    }
    _reachAnsweredAt.add(now);
    // The probe itself refuses anything but a public address.
    final int? latency = await _reachProbe(uri);
    _send(from, <String, dynamic>{
      'type': kLedgerReachOkType,
      'id': id,
      'ok': latency != null,
    });
  }

  void _onReachAnswer(String from, Map<String, dynamic> m) {
    final _ReachWait? wait = _reachWaits[m['id']];
    final String normalized = PeerShareCodec.normalizeAddress(from);
    if (wait == null ||
        !wait.asked.any(
          (String a) => PeerShareCodec.normalizeAddress(a) == normalized,
        ) ||
        !wait.answered.add(normalized) ||
        wait.done.isCompleted) {
      return;
    }
    if (m['ok'] == true) {
      wait.done.complete(ReachResult.reachable);
      return;
    }
    wait.noes++;
    if (wait.answered.length >= wait.asked.length) {
      wait.done.complete(ReachResult.unreachable);
    }
  }

  static String _randomId() {
    final Random r = Random.secure();
    return List<String>.generate(
      16,
      (_) => r.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
  }

  /// A separate key just for the bridge, so an announcement never reveals
  /// whose computer it is.
  Future<LedgerKeyPair> _bridgeKey() async {
    final Uint8List? raw = await disk.read(_bridgeKeyKey);
    if (raw != null && raw.length == 32) {
      return LedgerKeyPair.fromSeed(raw);
    }
    final LedgerKeyPair key = await LedgerKeyPair.generate();
    await disk.write(_bridgeKeyKey, key.seed);
    return key;
  }

  Future<void> _loadBridges() async {
    final Uint8List? raw = await disk.read(_bridgesKey);
    if (raw == null) {
      return;
    }
    try {
      final Object? json = jsonDecode(utf8.decode(raw));
      // A newer build's book stays as it is (saves are skipped).
      heldAsNewerOn(disk, _bridgesKey, json, current: 1);
      bridges.restore(json);
    } on FormatException {
      logZenWarning('Książka mostów jest uszkodzona; zaczynam od zera.');
    }
  }

  Future<void> _saveBridges() => disk.write(
    _bridgesKey,
    Uint8List.fromList(utf8.encode(jsonEncode(bridges.toJson()))),
  );

  Future<void> _loadPeers() async {
    final Uint8List? raw = await disk.read(_peersKey);
    if (raw == null) {
      return;
    }
    try {
      final Object? json = jsonDecode(utf8.decode(raw));
      if (json is Map) {
        json.forEach((Object? k, Object? v) {
          if (k is String && v is String) {
            _accounts[k] = v;
          }
        });
      }
    } on FormatException {
      logZenWarning('Lista kont znajomych w dzienniku jest uszkodzona.');
    }
  }

  Future<void> _loadFollowing() async {
    final Uint8List? raw = await disk.read(_followingKey);
    if (raw == null) {
      return;
    }
    try {
      final Object? json = jsonDecode(utf8.decode(raw));
      if (json is Map) {
        json.forEach((Object? k, Object? v) {
          if (k is String && v is String) {
            _followed[k] = v;
          }
        });
      }
    } on FormatException {
      logZenWarning('Lista obserwowanych jest uszkodzona.');
    }
  }

  Future<void> _saveFollowing() => disk.write(
    _followingKey,
    Uint8List.fromList(utf8.encode(jsonEncode(_followed))),
  );

  Future<void> _savePeers() => disk.write(
    _peersKey,
    Uint8List.fromList(utf8.encode(jsonEncode(_accounts))),
  );

  /// Stops for good; a second call waits for the first (the background
  /// service stops its ledger itself before its providers go away).
  Future<void> stop() => _stopping ??= _stop();
  Future<void>? _stopping;

  Future<void> _stop() async {
    _stopped = true;
    _syncTimer?.cancel();
    await _storeChanged?.cancel();
    await _devicesChanged.close();
    await _contactsChanged.close();
    await _peerGreeted.close();
    await _ownEntries.close();
    await _frames?.cancel();
    await _added?.cancel();
    await _openedChanges.close();
    await _blobDone.close();
    if (_started != null) {
      if (_loaded) {
        await archive.close();
      }
      await replicator.dispose();
    }
  }
}

final class _ReachWait {
  _ReachWait(this.asked);

  final Set<String> asked;
  final Set<String> answered = <String>{};
  final Completer<ReachResult> done = Completer<ReachResult>();
  int noes = 0;
}

/// This phone's clock, pulled back to its friends' when it runs more than
/// [ClockSkewTracker.warnThreshold] ahead of them (a clock set forward, by
/// hand or by a game): entries dated in friends' future would wait at every
/// friend until their time comes (they take nothing over ten minutes
/// ahead), and every later entry of the log behind them.
int friendsAgreedTime() {
  final int now = DateTime.now().millisecondsSinceEpoch;
  final Duration? skew = ClockSkewTracker.instance.estimate;
  return skew != null && skew < -ClockSkewTracker.warnThreshold
      ? now + skew.inMilliseconds
      : now;
}
