import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:intl/intl.dart';
import 'chat_screen.dart';
import 'profile_screen.dart';
import 'create_group_screen.dart';
import 'group_chat_screen.dart';
import 'new_chat_screen.dart';
import 'chats_tab.dart';
import 'groups_tab.dart';
import 'profile_tab.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final supabase = Supabase.instance.client;
  late final Stream<List<Map<String, dynamic>>> _groupMembershipStream;
  late final Stream<List<Map<String, dynamic>>> _messagesWatchStream;
  List<Map<String, dynamic>> _groups = [];
  List<Map<String, dynamic>> _conversations = [];
  String? _myAvatarUrl;
  bool _loadingConversations = true;
  final Set<String> _seenMessageIds = {};
  bool _seenIdsInitialized = false;

  @override
  void initState() {
    super.initState();
    final currentUserId = supabase.auth.currentUser!.id;

    _groupMembershipStream = supabase
        .from('group_members')
        .stream(primaryKey: ['group_id', 'user_id']).eq('user_id', currentUserId);
    _groupMembershipStream.listen((_) => _fetchGroups());

    _messagesWatchStream = supabase.from('messages').stream(primaryKey: ['id']);
    _messagesWatchStream.listen(_handleMessagesUpdate);

    _fetchGroups();
    _loadMyAvatar();
    _loadConversations();
  }

  void _handleMessagesUpdate(List<Map<String, dynamic>> rows) {
    final currentUserId = supabase.auth.currentUser!.id;
    if (!_seenIdsInitialized) {
      _seenMessageIds.addAll(rows.map((r) => r['id'] as String));
      _seenIdsInitialized = true;
    } else {
      for (final row in rows) {
        final id = row['id'] as String;
        if (!_seenMessageIds.contains(id)) {
          _seenMessageIds.add(id);
        }
        if (row['receiver_id'] == currentUserId && row['delivered_at'] == null) {
          supabase.from('messages').update({'delivered_at': DateTime.now().toIso8601String()}).eq('id', id);
        }
      }
    }
    _loadConversations();
  }

  Future<void> _loadMyAvatar() async {
    final currentUserId = supabase.auth.currentUser!.id;
    final data = await supabase.from('profiles').select('avatar_url').eq('id', currentUserId).maybeSingle();
    if (mounted) setState(() => _myAvatarUrl = data?['avatar_url']);
  }

  Future<void> _loadConversations() async {
    try {
      final response = await supabase.rpc('get_my_conversations');
      if (mounted) {
        setState(() {
          _conversations = List<Map<String, dynamic>>.from(response);
          _loadingConversations = false;
        });
      }
    } catch (e) {
      debugPrint('Failed to load conversations: $e');
      if (mounted) setState(() => _loadingConversations = false);
    }
  }

  Future<void> _fetchGroups() async {
    final currentUserId = supabase.auth.currentUser!.id;
    try {
      final response =
      await supabase.from('group_members').select('groups(id, name, created_by, avatar_url)').eq('user_id', currentUserId);
      final groups = (response as List).map((row) => row['groups'] as Map<String, dynamic>).toList();
      if (mounted) setState(() => _groups = groups);
    } catch (e) {
      debugPrint('Failed to fetch groups: $e');
    }
  }

  Future<void> _clearConversation(String otherUserId) async {
    final currentUserId = supabase.auth.currentUser!.id;
    try {
      await supabase.from('conversation_clears').upsert({
        'user_id': currentUserId,
        'other_user_id': otherUserId,
        'cleared_at': DateTime.now().toIso8601String(),
      });
      _loadConversations();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Failed to delete conversation. Check your connection.')),
        );
      }
    }
  }

  Future<void> _togglePin(String otherUserId, bool currentlyPinned) async {
    final currentUserId = supabase.auth.currentUser!.id;
    try {
      await supabase.from('conversation_clears').upsert({
        'user_id': currentUserId,
        'other_user_id': otherUserId,
        'pinned': !currentlyPinned,
      });
      _loadConversations();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Failed to update pin. Check your connection.')),
        );
      }
    }
  }

  Future<void> _signOut() async {
    final userId = supabase.auth.currentUser?.id;
    if (userId != null) {
      await supabase.from('profiles').update({
        'online': false,
        'last_seen': DateTime.now().toIso8601String(),
      }).eq('id', userId);
    }
    await supabase.auth.signOut();
  }

  String _formatTime(String? isoString) {
    if (isoString == null) return '';
    final dt = DateTime.parse(isoString).toLocal();
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final date = DateTime(dt.year, dt.month, dt.day);
    if (date == today) return DateFormat('h:mm a').format(dt);
    if (date == today.subtract(const Duration(days: 1))) return 'Yesterday';
    return DateFormat('MM/dd/yy').format(dt);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('ChitChat'),
        actions: [
          IconButton(
            icon: CircleAvatar(
              radius: 16,
              backgroundImage: _myAvatarUrl != null ? NetworkImage(_myAvatarUrl!) : null,
              child: _myAvatarUrl == null ? const Icon(Icons.person, size: 18) : null,
            ),
            tooltip: 'Profile',
            onPressed: () {
              Navigator.push(context, MaterialPageRoute(builder: (_) => const ProfileScreen()))
                  .then((_) => _loadMyAvatar());
            },
          ),
          PopupMenuButton<String>(
            onSelected: (value) {
              if (value == 'new_group') {
                Navigator.push(context, MaterialPageRoute(builder: (_) => const CreateGroupScreen()));
              } else if (value == 'sign_out') {
                _signOut();
              }
            },
            itemBuilder: (context) => [
              const PopupMenuItem(
                value: 'new_group',
                child: ListTile(leading: Icon(Icons.group_add_outlined), title: Text('New group')),
              ),
              const PopupMenuItem(
                value: 'sign_out',
                child: ListTile(leading: Icon(Icons.logout), title: Text('Sign out')),
              ),
            ],
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () {
          Navigator.push(context, MaterialPageRoute(builder: (_) => const NewChatScreen()))
              .then((_) => _loadConversations());
        },
        child: const Icon(Icons.chat),
      ),
      body: CustomScrollView(
        slivers: [
          if (_groups.isNotEmpty) ...[
            const SliverToBoxAdapter(
              child: Padding(
                padding: EdgeInsets.fromLTRB(16, 12, 16, 4),
                child: Text('Groups', style: TextStyle(fontWeight: FontWeight.bold, color: Colors.black54)),
              ),
            ),
            SliverList(
              delegate: SliverChildBuilderDelegate(
                    (context, index) {
                  final group = _groups[index];
                  return ListTile(
                    leading: CircleAvatar(
                      backgroundImage: group['avatar_url'] != null ? NetworkImage(group['avatar_url']) : null,
                      child: group['avatar_url'] == null ? const Icon(Icons.group) : null,
                    ),
                    title: Text(group['name'] ?? 'Unnamed group'),
                    onTap: () {
                      Navigator.push(
                        context,
                        MaterialPageRoute(builder: (_) => GroupChatScreen(groupId: group['id'], groupName: group['name'])),
                      );
                    },
                  );
                },
                childCount: _groups.length,
              ),
            ),
          ],
          const SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.fromLTRB(16, 16, 16, 4),
              child: Text('Chats', style: TextStyle(fontWeight: FontWeight.bold, color: Colors.black54)),
            ),
          ),
          if (_loadingConversations)
            const SliverToBoxAdapter(
              child: Padding(padding: EdgeInsets.all(24), child: Center(child: CircularProgressIndicator())),
            )
          else if (_conversations.isEmpty)
            const SliverToBoxAdapter(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Text('No conversations yet. Tap the chat button below to start one!', textAlign: TextAlign.center),
              ),
            )
          else
            SliverList(
              delegate: SliverChildBuilderDelegate(
                    (context, index) {
                  final conv = _conversations[index];
                  final otherUserId = conv['other_user_id'] as String;
                  final isOnline = conv['online'] == true;
                  final avatarUrl = conv['avatar_url'] as String?;
                  final unread = (conv['unread_count'] ?? 0) as int;
                  final isPinned = conv['pinned'] == true;
                  final lastMessage = conv['last_message'] as String?;
                  final lastImageUrl = conv['last_message_image_url'] as String?;
                  final preview =
                  (lastMessage != null && lastMessage.isNotEmpty) ? lastMessage : (lastImageUrl != null ? '📷 Photo' : '');

                  return Dismissible(
                    key: ValueKey('conv_$otherUserId'),
                    direction: DismissDirection.endToStart,
                    confirmDismiss: (direction) async {
                      final confirmed = await showDialog<bool>(
                        context: context,
                        builder: (context) => AlertDialog(
                          title: const Text('Delete conversation?'),
                          content: Text('This removes ${conv['username']} from your chat list. They can still message you again.'),
                          actions: [
                            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
                            TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('Delete')),
                          ],
                        ),
                      );
                      if (confirmed == true) _clearConversation(otherUserId);
                      return false;
                    },
                    background: Container(
                      alignment: Alignment.centerRight,
                      padding: const EdgeInsets.symmetric(horizontal: 20),
                      color: Colors.red.shade50,
                      child: const Icon(Icons.delete_outline, color: Colors.red),
                    ),
                    child: ListTile(
                      onLongPress: () => _togglePin(otherUserId, isPinned),
                      tileColor: isPinned ? Colors.black.withOpacity(0.03) : null,
                      leading: Stack(
                        children: [
                          CircleAvatar(
                            backgroundImage: avatarUrl != null ? NetworkImage(avatarUrl) : null,
                            child: avatarUrl == null
                                ? Text((conv['username'] as String).isNotEmpty ? conv['username'][0].toUpperCase() : '?')
                                : null,
                          ),
                          if (isOnline)
                            Positioned(
                              right: 0,
                              bottom: 0,
                              child: Container(
                                width: 12,
                                height: 12,
                                decoration: BoxDecoration(
                                  color: Colors.green,
                                  shape: BoxShape.circle,
                                  border: Border.all(color: Colors.white, width: 2),
                                ),
                              ),
                            ),
                        ],
                      ),
                      title: Row(
                        children: [
                          if (isPinned) const Padding(padding: EdgeInsets.only(right: 4), child: Icon(Icons.push_pin, size: 14)),
                          Expanded(child: Text(conv['username'] ?? 'Unknown')),
                        ],
                      ),
                      subtitle: Text(
                        preview,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: unread > 0 ? const TextStyle(fontWeight: FontWeight.bold) : null,
                      ),
                      trailing: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          Text(_formatTime(conv['last_message_at'] as String?), style: const TextStyle(fontSize: 11, color: Colors.black54)),
                          const SizedBox(height: 4),
                          if (unread > 0)
                            CircleAvatar(
                              radius: 11,
                              backgroundColor: Colors.red,
                              child: Text('$unread', style: const TextStyle(color: Colors.white, fontSize: 11)),
                            ),
                        ],
                      ),
                      onTap: () {
                        Navigator.push(
                          context,
                          MaterialPageRoute(builder: (_) => ChatScreen(receiverId: otherUserId, receiverUsername: conv['username'])),
                        ).then((_) => _loadConversations());
                      },
                    ),
                  );
                },
                childCount: _conversations.length,
              ),
            ),
        ],
      ),
    );
  }
}