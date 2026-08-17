import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'group_chat_screen.dart';

class GroupsTab extends StatefulWidget {
  const GroupsTab({super.key});

  @override
  State<GroupsTab> createState() => _GroupsTabState();
}

class _GroupsTabState extends State<GroupsTab> {
  final supabase = Supabase.instance.client;
  late final Stream<List<Map<String, dynamic>>> _groupMembershipStream;
  late final Stream<List<Map<String, dynamic>>> _groupMessagesWatchStream;
  List<Map<String, dynamic>> _groups = [];
  Map<String, int> _unreadCounts = {};
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    final currentUserId = supabase.auth.currentUser!.id;
    _groupMembershipStream = supabase.from('group_members').stream(primaryKey: ['group_id', 'user_id']).eq('user_id', currentUserId);
    _groupMembershipStream.listen((_) => _fetchGroups());

    _groupMessagesWatchStream = supabase.from('group_messages').stream(primaryKey: ['id']);
    _groupMessagesWatchStream.listen((_) => _fetchGroups());

    _fetchGroups();
  }

  Future<void> _fetchGroups() async {
    final currentUserId = supabase.auth.currentUser!.id;
    try {
      final response = await supabase.from('group_members').select('groups(id, name, created_by, avatar_url)').eq('user_id', currentUserId);
      final groups = (response as List).map((row) => row['groups'] as Map<String, dynamic>).toList();

      final unreadResponse = await supabase.rpc('get_my_group_unread_counts');
      final unreadMap = <String, int>{};
      for (final row in unreadResponse as List) {
        unreadMap[row['group_id']] = (row['unread_count'] as num).toInt();
      }

      if (mounted) {
        setState(() {
          _groups = groups;
          _unreadCounts = unreadMap;
          _loading = false;
        });
      }
    } catch (e) {
      debugPrint('Failed to fetch groups: $e');
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_groups.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.group_outlined, size: 64, color: Colors.black26),
              const SizedBox(height: 16),
              const Text('No groups yet', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
              const SizedBox(height: 4),
              const Text('Tap + above to create one', style: TextStyle(color: Colors.black54)),
            ],
          ),
        ),
      );
    }
    return RefreshIndicator(
      onRefresh: _fetchGroups,
      child: ListView.builder(
        itemCount: _groups.length,
        itemBuilder: (context, index) {
          final group = _groups[index];
          final groupId = group['id'] as String;
          final unread = _unreadCounts[groupId] ?? 0;
          return ListTile(
            leading: CircleAvatar(
              backgroundImage: group['avatar_url'] != null ? NetworkImage(group['avatar_url']) : null,
              child: group['avatar_url'] == null ? const Icon(Icons.group) : null,
            ),
            title: Text(group['name'] ?? 'Unnamed group', style: unread > 0 ? const TextStyle(fontWeight: FontWeight.bold) : null),
            trailing: unread > 0
                ? CircleAvatar(radius: 11, backgroundColor: Colors.red, child: Text('$unread', style: const TextStyle(color: Colors.white, fontSize: 11)))
                : null,
            onTap: () {
              Navigator.push(context, MaterialPageRoute(builder: (_) => GroupChatScreen(groupId: groupId, groupName: group['name'])))
                  .then((_) => _fetchGroups());
            },
          );
        },
      ),
    );
  }
}