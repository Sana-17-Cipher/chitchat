import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:intl/intl.dart';
import 'package:image_picker/image_picker.dart';

class GroupChatScreen extends StatefulWidget {
  final String groupId;
  final String groupName;

  const GroupChatScreen({super.key, required this.groupId, required this.groupName});

  @override
  State<GroupChatScreen> createState() => _GroupChatScreenState();
}

class _GroupChatScreenState extends State<GroupChatScreen> {
  final supabase = Supabase.instance.client;
  final _messageController = TextEditingController();
  final _scrollController = ScrollController();
  final ImagePicker _picker = ImagePicker();
  late final String _currentUserId;
  late final Stream<List<Map<String, dynamic>>> _messagesStream;

  Map<String, Map<String, dynamic>> _memberInfo = {};
  String? _groupAvatarUrl;
  bool _isCreator = false;
  bool _uploadingAvatar = false;

  @override
  void initState() {
    super.initState();
    _currentUserId = supabase.auth.currentUser!.id;

    _messagesStream = supabase
        .from('group_messages')
        .stream(primaryKey: ['id'])
        .eq('group_id', widget.groupId)
        .order('created_at', ascending: true);

    _loadMembers();
    _loadGroupInfo();
  }

  Future<void> _loadGroupInfo() async {
    try {
      final data = await supabase.from('groups').select('avatar_url, created_by').eq('id', widget.groupId).single();
      if (mounted) {
        setState(() {
          _groupAvatarUrl = data['avatar_url'];
          _isCreator = data['created_by'] == _currentUserId;
        });
      }
    } catch (e) {
      debugPrint('Failed to load group info: $e');
    }
  }

  Future<void> _pickAndUploadGroupAvatar() async {
    final XFile? picked = await _picker.pickImage(source: ImageSource.gallery, maxWidth: 800, imageQuality: 85);
    if (picked == null) return;

    setState(() => _uploadingAvatar = true);
    try {
      final bytes = await picked.readAsBytes();
      final ext = picked.name.contains('.') ? picked.name.split('.').last : 'jpg';
      final path = 'groups/${widget.groupId}/avatar.$ext';

      await supabase.storage.from('avatars').uploadBinary(path, bytes, fileOptions: const FileOptions(upsert: true));
      final publicUrl =
          '${supabase.storage.from('avatars').getPublicUrl(path)}?t=${DateTime.now().millisecondsSinceEpoch}';

      await supabase.from('groups').update({'avatar_url': publicUrl}).eq('id', widget.groupId);
      if (mounted) setState(() => _groupAvatarUrl = publicUrl);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Failed to update group photo. Check your connection.')),
        );
      }
    } finally {
      if (mounted) setState(() => _uploadingAvatar = false);
    }
  }

  Future<void> _loadMembers() async {
    try {
      final response = await supabase
          .from('group_members')
          .select('user_id, profiles(username, avatar_url)')
          .eq('group_id', widget.groupId);

      final map = <String, Map<String, dynamic>>{};
      for (final row in response as List) {
        final profile = row['profiles'] as Map<String, dynamic>?;
        map[row['user_id']] = {
          'username': profile?['username'] ?? 'Unknown',
          'avatar_url': profile?['avatar_url'],
        };
      }
      if (mounted) setState(() => _memberInfo = map);
    } catch (e) {
      debugPrint('Failed to load group members: $e');
    }
  }

  Future<void> _sendMessage() async {
    final text = _messageController.text.trim();
    if (text.isEmpty) return;

    try {
      await supabase.from('group_messages').insert({
        'group_id': widget.groupId,
        'sender_id': _currentUserId,
        'content': text,
      });
      _messageController.clear();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Message failed to send. Check your connection and try again.')),
        );
      }
    }
  }

  Future<void> _confirmDelete(String messageId) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete message?'),
        content: const Text('This will delete the message for everyone.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('Delete')),
        ],
      ),
    );

    if (confirmed == true) {
      try {
        await supabase.from('group_messages').delete().eq('id', messageId);
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Failed to delete message. Check your connection.')),
          );
        }
      }
    }
  }

  String _formatDateDivider(DateTime date) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final messageDate = DateTime(date.year, date.month, date.day);

    if (messageDate == today) return 'Today';
    if (messageDate == today.subtract(const Duration(days: 1))) return 'Yesterday';
    return DateFormat('MMMM d, yyyy').format(date);
  }

  @override
  void dispose() {
    _messageController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        leading: Padding(
          padding: const EdgeInsets.all(8.0),
          child: GestureDetector(
            onTap: _isCreator && !_uploadingAvatar ? _pickAndUploadGroupAvatar : null,
            child: Stack(
              children: [
                CircleAvatar(
                  backgroundImage: _groupAvatarUrl != null ? NetworkImage(_groupAvatarUrl!) : null,
                  child: _groupAvatarUrl == null ? const Icon(Icons.group) : null,
                ),
                if (_isCreator)
                  Positioned(
                    right: -2,
                    bottom: -2,
                    child: Container(
                      padding: const EdgeInsets.all(3),
                      decoration: BoxDecoration(
                        color: Theme.of(context).colorScheme.primary,
                        shape: BoxShape.circle,
                        border: Border.all(color: Colors.white, width: 1.5),
                      ),
                      child: _uploadingAvatar
                          ? const SizedBox(height: 10, width: 10, child: CircularProgressIndicator(strokeWidth: 1.5))
                          : const Icon(Icons.camera_alt, size: 10, color: Colors.black87),
                    ),
                  ),
              ],
            ),
          ),
        ),
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(widget.groupName),
            Text('${_memberInfo.length} members', style: const TextStyle(fontSize: 12)),
          ],
        ),
      ),
      body: Column(
        children: [
          Expanded(
            child: StreamBuilder<List<Map<String, dynamic>>>(
              stream: _messagesStream,
              builder: (context, snapshot) {
                if (snapshot.hasError) {
                  return const Center(
                    child: Padding(
                      padding: EdgeInsets.all(24),
                      child: Text('Couldn\'t load messages. Check your connection.', textAlign: TextAlign.center),
                    ),
                  );
                }
                if (!snapshot.hasData) {
                  return const Center(child: CircularProgressIndicator());
                }
                final messages = snapshot.data!;

                if (messages.isEmpty) {
                  return const Center(child: Text('No messages yet — say hi 👋'));
                }

                WidgetsBinding.instance.addPostFrameCallback((_) {
                  if (_scrollController.hasClients) {
                    _scrollController.animateTo(
                      _scrollController.position.maxScrollExtent,
                      duration: const Duration(milliseconds: 200),
                      curve: Curves.easeOut,
                    );
                  }
                });

                return ListView.builder(
                  controller: _scrollController,
                  padding: const EdgeInsets.all(12),
                  itemCount: messages.length,
                  itemBuilder: (context, index) {
                    final msg = messages[index];
                    final isMe = msg['sender_id'] == _currentUserId;
                    final senderInfo = _memberInfo[msg['sender_id']];
                    final senderName = senderInfo?['username'] ?? 'Unknown';
                    final avatarUrl = senderInfo?['avatar_url'] as String?;
                    final time = DateTime.parse(msg['created_at']).toLocal();

                    final showName =
                        !isMe && (index == 0 || messages[index - 1]['sender_id'] != msg['sender_id']);

                    final showDateDivider = index == 0 ||
                        DateTime.parse(messages[index - 1]['created_at']).toLocal().day != time.day ||
                        DateTime.parse(messages[index - 1]['created_at']).toLocal().month != time.month ||
                        DateTime.parse(messages[index - 1]['created_at']).toLocal().year != time.year;

                    return Column(
                      children: [
                        if (showDateDivider)
                          Padding(
                            padding: const EdgeInsets.symmetric(vertical: 12),
                            child: Center(
                              child: Container(
                                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                                decoration: BoxDecoration(
                                  color: Colors.black12,
                                  borderRadius: BorderRadius.circular(12),
                                ),
                                child: Text(
                                  _formatDateDivider(time),
                                  style: const TextStyle(fontSize: 12, color: Colors.black54),
                                ),
                              ),
                            ),
                          ),
                        Align(
                          key: ValueKey(msg['id']),
                          alignment: isMe ? Alignment.centerRight : Alignment.centerLeft,
                          child: Dismissible(
                            key: ValueKey('dismiss_${msg['id']}'),
                            direction: isMe ? DismissDirection.endToStart : DismissDirection.startToEnd,
                            confirmDismiss: (direction) async {
                              if (isMe) {
                                _confirmDelete(msg['id']);
                              } else {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(content: Text('Replying to: "${msg['content'] ?? '[message]'}"')),
                                );
                              }
                              return false;
                            },
                            background: Container(
                              alignment: isMe ? Alignment.centerRight : Alignment.centerLeft,
                              padding: const EdgeInsets.symmetric(horizontal: 20),
                              child: Icon(isMe ? Icons.delete_outline : Icons.reply, color: Colors.black45),
                            ),
                            child: GestureDetector(
                              onLongPress: isMe ? () => _confirmDelete(msg['id']) : null,
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                crossAxisAlignment: CrossAxisAlignment.end,
                                children: [
                                  if (!isMe) ...[
                                    CircleAvatar(
                                      radius: 14,
                                      backgroundImage: avatarUrl != null ? NetworkImage(avatarUrl) : null,
                                      child: avatarUrl == null
                                          ? Text(senderName.isNotEmpty ? senderName[0].toUpperCase() : '?',
                                          style: const TextStyle(fontSize: 12))
                                          : null,
                                    ),
                                    const SizedBox(width: 6),
                                  ],
                                  Container(
                                    margin: const EdgeInsets.symmetric(vertical: 4),
                                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                                    constraints:
                                    BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.65),
                                    decoration: BoxDecoration(
                                      color: isMe ? const Color(0xFFC9E4B0) : const Color(0xFFE0D4F0),
                                      borderRadius: BorderRadius.circular(16),
                                    ),
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        if (showName)
                                          Padding(
                                            padding: const EdgeInsets.only(bottom: 2),
                                            child: Text(
                                              senderName,
                                              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12),
                                            ),
                                          ),
                                        Text(msg['content'] ?? '', style: const TextStyle(color: Colors.black87)),
                                        const SizedBox(height: 4),
                                        Text(
                                          DateFormat('h:mm a').format(time),
                                          style: const TextStyle(fontSize: 10, color: Colors.black54),
                                        ),
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ],
                    );
                  },
                );
              },
            ),
          ),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(8.0),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _messageController,
                      decoration: InputDecoration(
                        hintText: 'Type a message...',
                        border: OutlineInputBorder(borderRadius: BorderRadius.circular(24)),
                        contentPadding: const EdgeInsets.symmetric(horizontal: 16),
                      ),
                      onSubmitted: (_) => _sendMessage(),
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton.filled(icon: const Icon(Icons.send), onPressed: _sendMessage),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}