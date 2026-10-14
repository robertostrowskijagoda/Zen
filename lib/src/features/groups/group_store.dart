import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zen/src/core/storage/binary_store.dart';
import 'package:zen/src/domain/groups/group_profile.dart';

abstract interface class GroupStore {
  Future<Map<String, GroupProfile>> load();
  Future<void> save(Map<String, GroupProfile> groups);
}

final class MemoryGroupStore implements GroupStore {
  Map<String, GroupProfile> _groups = <String, GroupProfile>{};

  @override
  Future<Map<String, GroupProfile>> load() async => _groups;

  @override
  Future<void> save(Map<String, GroupProfile> groups) async {
    _groups = Map<String, GroupProfile>.from(groups);
  }
}

final class FileGroupStore implements GroupStore {
  FileGroupStore({required this.store, this.storageKey = 'groups'});

  final FileBinaryStore store;
  final String storageKey;

  @override
  Future<Map<String, GroupProfile>> load() async {
    try {
      final Uint8List? bytes = await store.read(storageKey);
      if (bytes == null || bytes.isEmpty) {
        return <String, GroupProfile>{};
      }
      final List<dynamic> list =
          jsonDecode(utf8.decode(bytes)) as List<dynamic>;
      final Map<String, GroupProfile> result = <String, GroupProfile>{};
      for (final dynamic item in list) {
        if (item is Map<String, dynamic>) {
          final GroupProfile group = GroupProfile.fromJson(item);
          result[group.id] = group;
        }
      }
      return result;
    } catch (_) {
      return <String, GroupProfile>{};
    }
  }

  @override
  Future<void> save(Map<String, GroupProfile> groups) async {
    final List<Map<String, dynamic>> list = groups.values
        .map((GroupProfile g) => g.toJson())
        .toList();
    final String jsonStr = jsonEncode(list);
    await store.write(storageKey, Uint8List.fromList(utf8.encode(jsonStr)));
  }
}

final Provider<GroupStore> groupStoreProvider = Provider<GroupStore>((Ref ref) {
  return MemoryGroupStore();
});
