import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:intl/intl.dart';
import 'chat_screen.dart';

class ChatsTab extends StatefulWidget {
  const ChatsTab({super.key});

  @override
  State<ChatsTab> createState() => _ChatsTabState();
}

class _ChatsTabState extends State<ChatsTab> {
  final supabase = Supabase.instance.client;
  late final Stream<List<Map<String, dynamic>>> _messagesWatchStream;
  List<Map<String, dynamic>> _conversations = [];
  bool _loading = true;
  bool _failed = false;
  final Set<String> _seenMessageIds = {};
  bool _seenIdsInitialized = false;

  @override
  void initState() {
    super.initState();
    _messagesWatchStream = supabase.from('messages').stream(primaryKey: ['id']);
    _messagesWatchStream.listen(_handleMessagesUpdate);
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
        if (!_seenMessageIds.contains(id)) _seenMessageIds.add(id);
        if (row['receiver_id'] == currentUserId && row['delivered_at'] == null) {
          supabase.from('messages').update({'delivered_at': DateTime.now().toIso8601String()}).eq('id', id);
        }
      }
    }
    _loadConversations();
  }

  Future<void> _loadConversations() async {
    try {
      final response = await supabase.rpc('get_my_conversations');
      if (mounted) {
        setState(() {
          _conversations = List<Map<String, dynamic>>.from(response);
          _loading = false;
          _failed = false;
        });
      }
    } catch (e) {
      debugPrint('LOAD CONVERSATIONS ERROR: $e');
      if (mounted) {
        setState(() {
          _loading = false;
          _failed = true;
        });
      }
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
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_failed) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.error_outline, size: 48, color: Colors.red),
              const SizedBox(height: 16),
              const Text('Couldn\'t load your chats.', style: TextStyle(fontWeight: FontWeight.bold)),
              const SizedBox(height: 4),
              const Text('Check your connection and try again.', style: TextStyle(color: Colors.black54)),
              const SizedBox(height: 16),
              FilledButton(onPressed: _loadConversations, child: const Text('Retry')),
            ],
          ),
        ),
      );
    }
    if (_conversations.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.chat_bubble_outline, size: 64, color: Colors.black26),
              const SizedBox(height: 16),
              const Text('No conversations yet', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
              const SizedBox(height: 4),
              const Text('Tap the chat button to start one', style: TextStyle(color: Colors.black54), textAlign: TextAlign.center),
            ],
          ),
        ),
      );
    }
    return RefreshIndicator(
      onRefresh: _loadConversations,
      child: ListView.builder(
        itemCount: _conversations.length,
        itemBuilder: (context, index) {
          final conv = _conversations[index];
          final otherUserId = conv['other_user_id'] as String;
          final isOnline = conv['online'] == true;
          final avatarUrl = conv['avatar_url'] as String?;
          final unread = (conv['unread_count'] ?? 0) as int;
          final isPinned = conv['pinned'] == true;
          final lastMessage = conv['last_message'] as String?;
          final lastImageUrl = conv['last_message_image_url'] as String?;
          final preview = (lastMessage != null && lastMessage.isNotEmpty) ? lastMessage : (lastImageUrl != null ? '📷 Photo' : '');

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
                        decoration: BoxDecoration(color: Colors.green, shape: BoxShape.circle, border: Border.all(color: Colors.white, width: 2)),
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
              subtitle: Text(preview, maxLines: 1, overflow: TextOverflow.ellipsis, style: unread > 0 ? const TextStyle(fontWeight: FontWeight.bold) : null),
              trailing: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(_formatTime(conv['last_message_at'] as String?), style: const TextStyle(fontSize: 11, color: Colors.black54)),
                  const SizedBox(height: 4),
                  if (unread > 0)
                    CircleAvatar(radius: 11, backgroundColor: Colors.red, child: Text('$unread', style: const TextStyle(color: Colors.white, fontSize: 11))),
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
      ),
    );
  }
}