import 'package:zen/src/features/about/presentation/about_screen.dart';
import 'package:zen/src/features/social/peer_share_codec.dart';
import 'package:zen/src/features/update/release.dart';

/// The author named in official releases (the signed manifest carries it).
const String kOfficialAuthor = 'Robert Ostrowski-Jagoda';

/// What this build shows people: the donation link of "O aplikacji", the
/// author and the repository. Compared with the maintainers' signed
/// [OfficialInfo] (§14.3 point 6) — taken from the very constants the
/// screens use, so a copy that swaps the link is caught.
OfficialInfo thisBuildOfficialInfo() => const OfficialInfo(
  donation: kDonationUrl,
  author: kOfficialAuthor,
  repository: PeerShareCodec.repositoryUrl,
);
