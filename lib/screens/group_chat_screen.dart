import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:intl/intl.dart';
import 'package:image_picker/image_picker.dart';
import 'group_info_screen.dart';
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
  bool _uploadingImage = false;
  Map<String, dynamic>? _replyingTo;

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
      final publicUrl = '${supabase.storage.from('avatars').getPublicUrl(path)}?t=${DateTime.now().millisecondsSinceEpoch}';

      await supabase.from('groups').update({'avatar_url': publicUrl}).eq('id', widget.groupId);
      if (mounted) setState(() => _groupAvatarUrl = publicUrl);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Failed to update group photo. Check your connection.')));
      }
    } finally {
      if (mounted) setState(() => _uploadingAvatar = false);
    }
  }

  Future<void> _loadMembers() async {
    try {
      final response = await supabase.from('group_members').select('user_id, profiles(username, avatar_url)').eq('group_id', widget.groupId);
      final map = <String, Map<String, dynamic>>{};
      for (final row in response as List) {
        final profile = row['profiles'] as Map<String, dynamic>?;
        map[row['user_id']] = {'username': profile?['username'] ?? 'Unknown', 'avatar_url': profile?['avatar_url']};
      }
      if (mounted) setState(() => _memberInfo = map);
    } catch (e) {
      debugPrint('Failed to load group members: $e');
    }
  }
  Future<void> _markGroupAsRead() async {
    try {
      await supabase.from('group_members').update({'last_read_at': DateTime.now().toIso8601String()}).eq('group_id', widget.groupId).eq('user_id', _currentUserId);
    } catch (e) {
      debugPrint('Failed to mark group as read: $e');
    }
  }



  Future<void> _sendMessage() async {
    final text = _messageController.text.trim();
    if (text.isEmpty) return;

    final replyToId = _replyingTo?['id'];

    try {
      await supabase.from('group_messages').insert({
        'group_id': widget.groupId,
        'sender_id': _currentUserId,
        'content': text,
        if (replyToId != null) 'reply_to_id': replyToId,
      });
      _messageController.clear();
      setState(() => _replyingTo = null);
    } catch (e) {
      debugPrint('SEND GROUP MESSAGE ERROR: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Message failed to send. Check your connection and try again.')));
      }
    }
  }

  Future<void> _pickAndSendImages() async {
    final List<XFile> picked = await _picker.pickMultiImage(imageQuality: 80);
    if (picked.isEmpty) return;
    setState(() => _uploadingImage = true);
    try {
      final List<String> urls = [];
      for (final file in picked) {
        final bytes = await file.readAsBytes();
        final ext = file.name.contains('.') ? file.name.split('.').last : 'jpg';
        final path = '$_currentUserId/${DateTime.now().millisecondsSinceEpoch}_${urls.length}.$ext';
        await supabase.storage.from('chat_images').uploadBinary(path, bytes, fileOptions: const FileOptions(upsert: false));
        urls.add(supabase.storage.from('chat_images').getPublicUrl(path));
      }
      await supabase.from('group_messages').insert({
        'group_id': widget.groupId,
        'sender_id': _currentUserId,
        'image_urls': urls,
      });
    } catch (e) {
      debugPrint('GROUP IMAGE UPLOAD ERROR: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Failed to send images. Check your connection and try again.')));
      }
    } finally {
      if (mounted) setState(() => _uploadingImage = false);
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
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Failed to delete message. Check your connection.')));
        }
      }
    }
  }

  void _showMessageOptions(Map<String, dynamic> msg, bool isMe, String? content) {
    showModalBottomSheet(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.reply),
              title: const Text('Reply'),
              onTap: () {
                Navigator.pop(context);
                setState(() => _replyingTo = msg);
              },
            ),
            if (content != null && content.isNotEmpty)
              ListTile(
                leading: const Icon(Icons.copy_outlined),
                title: const Text('Copy text'),
                onTap: () {
                  Navigator.pop(context);
                  Clipboard.setData(ClipboardData(text: content));
                  ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Copied')));
                },
              ),
            if (isMe)
              ListTile(
                leading: const Icon(Icons.delete_outline, color: Colors.red),
                title: const Text('Delete', style: TextStyle(color: Colors.red)),
                onTap: () {
                  Navigator.pop(context);
                  _confirmDelete(msg['id']);
                },
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _leaveGroup() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Leave group?'),
        content: Text('You\'ll be removed from "${widget.groupName}".'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('Leave')),
        ],
      ),
    );
    if (confirmed == true) {
      try {
        await supabase.from('group_members').delete().eq('group_id', widget.groupId).eq('user_id', _currentUserId);
        if (mounted) Navigator.pop(context);
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Failed to leave group. Check your connection.')));
        }
      }
    }
  }

  void _openFullImage(String url) {
    showDialog(
      context: context,
      builder: (context) => Dialog(
        backgroundColor: Colors.black,
        insetPadding: const EdgeInsets.all(12),
        child: InteractiveViewer(child: Image.network(url, fit: BoxFit.contain)),
      ),
    );
  }

  void _openImageGallery(List<String> urls, int initialIndex) {
    showDialog(
      context: context,
      builder: (context) => Dialog(
        backgroundColor: Colors.black,
        insetPadding: const EdgeInsets.all(12),
        child: SizedBox(
          height: 500,
          child: PageView.builder(
            controller: PageController(initialPage: initialIndex),
            itemCount: urls.length,
            itemBuilder: (context, i) => InteractiveViewer(child: Image.network(urls[i], fit: BoxFit.contain)),
          ),
        ),
      ),
    );
  }

  Widget _buildImageGrid(List<String> urls) {
    if (urls.length == 1) {
      return GestureDetector(
        onTap: () => _openImageGallery(urls, 0),
        child: ClipRRect(borderRadius: BorderRadius.circular(12), child: AspectRatio(aspectRatio: 4 / 3, child: Image.network(urls[0], fit: BoxFit.cover))),
      );
    }
    if (urls.length == 2) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: SizedBox(
          height: 140,
          child: Row(
            children: [
              Expanded(child: GestureDetector(onTap: () => _openImageGallery(urls, 0), child: Image.network(urls[0], fit: BoxFit.cover, height: double.infinity))),
              const SizedBox(width: 2),
              Expanded(child: GestureDetector(onTap: () => _openImageGallery(urls, 1), child: Image.network(urls[1], fit: BoxFit.cover, height: double.infinity))),
            ],
          ),
        ),
      );
    }
    final belowCount = (urls.length - 1) > 3 ? 3 : (urls.length - 1);
    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          GestureDetector(onTap: () => _openImageGallery(urls, 0), child: AspectRatio(aspectRatio: 16 / 9, child: Image.network(urls[0], fit: BoxFit.cover))),
          const SizedBox(height: 2),
          SizedBox(
            height: 80,
            child: Row(
              children: List.generate(belowCount, (i) {
                final urlIndex = i + 1;
                final isLastOverlay = i == 2 && urls.length > 4;
                return Expanded(
                  child: Padding(
                    padding: EdgeInsets.only(left: i == 0 ? 0 : 2),
                    child: GestureDetector(
                      onTap: () => _openImageGallery(urls, urlIndex),
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          Image.network(urls[urlIndex], fit: BoxFit.cover),
                          if (isLastOverlay)
                            Container(color: Colors.black54, child: Center(child: Text('+${urls.length - 4}', style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold)))),
                        ],
                      ),
                    ),
                  ),
                );
              }),
            ),
          ),
        ],
      ),
    );
  }

  String _formatDateDivider(DateTime date) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final messageDate = DateTime(date.year, date.month, date.day);
    if (messageDate == today) return 'Today';
    if (messageDate == today.subtract(const Duration(days: 1))) return 'Yesterday';
    return DateFormat('MMMM d, yyyy').format(date);
  }

  Map<String, dynamic>? _findMessageById(List<Map<String, dynamic>> messages, String? id) {
    if (id == null) return null;
    try {
      return messages.firstWhere((m) => m['id'] == id);
    } catch (e) {
      return null;
    }
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
        title: GestureDetector(
          onTap: () {
            Navigator.push(context, MaterialPageRoute(builder: (_) => GroupInfoScreen(groupId: widget.groupId)))
                .then((_) {
              _loadMembers();
              _loadGroupInfo();
            });
          },
          child: Row(
            children: [
              CircleAvatar(
                backgroundImage: _groupAvatarUrl != null ? NetworkImage(_groupAvatarUrl!) : null,
                child: _groupAvatarUrl == null ? const Icon(Icons.group) : null,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(widget.groupName, overflow: TextOverflow.ellipsis),
                    Text('${_memberInfo.length} members', style: const TextStyle(fontSize: 12)),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
      body: Column(
        children: [
          Expanded(
            child: StreamBuilder<List<Map<String, dynamic>>>(
              stream: _messagesStream,
              builder: (context, snapshot) {
                if (snapshot.hasError) {
                  return const Center(child: Padding(padding: EdgeInsets.all(24), child: Text('Couldn\'t load messages. Check your connection.', textAlign: TextAlign.center)));
                }
                if (!snapshot.hasData) {
                  return const Center(child: CircularProgressIndicator());
                }
                final messages = snapshot.data!;
                if (messages.isEmpty) {
                  return const Center(child: Text('No messages yet — say hi 👋'));
                }
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  _markGroupAsRead();
                  if (_scrollController.hasClients) {
                    _scrollController.animateTo(_scrollController.position.maxScrollExtent, duration: const Duration(milliseconds: 200), curve: Curves.easeOut);
                  }
                });

                WidgetsBinding.instance.addPostFrameCallback((_) {
                  _markGroupAsRead();
                  if (_scrollController.hasClients) {
                    _scrollController.animateTo(_scrollController.position.maxScrollExtent, duration: const Duration(milliseconds: 200), curve: Curves.easeOut);
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
                    final imageUrl = msg['image_url'] as String?;
                    final imageUrls = (msg['image_urls'] as List?)?.cast<String>();
                    final content = msg['content'] as String?;
                    final quoted = _findMessageById(messages, msg['reply_to_id'] as String?);
                    final hasImages = (imageUrls != null && imageUrls.isNotEmpty) || imageUrl != null;

                    final showName = !isMe && (index == 0 || messages[index - 1]['sender_id'] != msg['sender_id']);

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
                                decoration: BoxDecoration(color: Colors.black12, borderRadius: BorderRadius.circular(12)),
                                child: Text(_formatDateDivider(time), style: const TextStyle(fontSize: 12, color: Colors.black54)),
                              ),
                            ),
                          ),
                        Align(
                          key: ValueKey(msg['id']),
                          alignment: isMe ? Alignment.centerRight : Alignment.centerLeft,
                          child: Dismissible(
                            key: ValueKey('dismiss_${msg['id']}'),
                            direction: DismissDirection.horizontal,
                            confirmDismiss: (direction) async {
                              setState(() => _replyingTo = msg);
                              return false;
                            },
                            background: Container(alignment: Alignment.centerLeft, padding: const EdgeInsets.symmetric(horizontal: 20), child: const Icon(Icons.reply, color: Colors.black45)),
                            secondaryBackground: Container(alignment: Alignment.centerRight, padding: const EdgeInsets.symmetric(horizontal: 20), child: const Icon(Icons.reply, color: Colors.black45)),
                            child: GestureDetector(
                              onLongPress: () => _showMessageOptions(msg, isMe, content),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                crossAxisAlignment: CrossAxisAlignment.end,
                                children: [
                                  if (!isMe) ...[
                                    CircleAvatar(
                                      radius: 14,
                                      backgroundImage: avatarUrl != null ? NetworkImage(avatarUrl) : null,
                                      child: avatarUrl == null ? Text(senderName.isNotEmpty ? senderName[0].toUpperCase() : '?', style: const TextStyle(fontSize: 12)) : null,
                                    ),
                                    const SizedBox(width: 6),
                                  ],
                                  Container(
                                    margin: const EdgeInsets.symmetric(vertical: 4),
                                    padding: hasImages ? const EdgeInsets.all(4) : const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                                    constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.65),
                                    decoration: BoxDecoration(
                                      color: isMe ? const Color(0xFFC9E4B0) : const Color(0xFFE0D4F0),
                                      borderRadius: BorderRadius.circular(16),
                                    ),
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        if (showName)
                                          Padding(padding: const EdgeInsets.only(bottom: 2), child: Text(senderName, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12))),
                                        if (quoted != null)
                                          Container(
                                            margin: const EdgeInsets.only(bottom: 6),
                                            padding: const EdgeInsets.all(8),
                                            decoration: BoxDecoration(
                                              color: Colors.black.withOpacity(0.06),
                                              borderRadius: BorderRadius.circular(8),
                                              border: Border(left: BorderSide(color: Theme.of(context).colorScheme.primary, width: 3)),
                                            ),
                                            child: Text(
                                              (quoted['content'] as String?)?.isNotEmpty == true ? quoted['content'] : '📷 Photo',
                                              maxLines: 2,
                                              overflow: TextOverflow.ellipsis,
                                              style: const TextStyle(fontSize: 12, color: Colors.black54),
                                            ),
                                          ),
                                        if (imageUrls != null && imageUrls.isNotEmpty)
                                          _buildImageGrid(imageUrls)
                                        else if (imageUrl != null)
                                          GestureDetector(
                                            onTap: () => _openFullImage(imageUrl),
                                            child: ClipRRect(borderRadius: BorderRadius.circular(12), child: Image.network(imageUrl, fit: BoxFit.cover)),
                                          ),
                                        if (content != null && content.isNotEmpty)
                                          Padding(
                                            padding: hasImages ? const EdgeInsets.only(top: 6) : EdgeInsets.zero,
                                            child: Text(content, style: const TextStyle(color: Colors.black87)),
                                          ),
                                        const SizedBox(height: 4),
                                        Text(DateFormat('h:mm a').format(time), style: const TextStyle(fontSize: 10, color: Colors.black54)),
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
          if (_replyingTo != null)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              color: Colors.black.withOpacity(0.05),
              child: Row(
                children: [
                  Container(width: 3, height: 32, color: Theme.of(context).colorScheme.primary),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          _replyingTo!['sender_id'] == _currentUserId ? 'Replying to yourself' : 'Replying to ${_memberInfo[_replyingTo!['sender_id']]?['username'] ?? 'them'}',
                          style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12),
                        ),
                        Text(
                          (_replyingTo!['content'] as String?)?.isNotEmpty == true ? _replyingTo!['content'] : '📷 Photo',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 12, color: Colors.black54),
                        ),
                      ],
                    ),
                  ),
                  IconButton(icon: const Icon(Icons.close, size: 18), onPressed: () => setState(() => _replyingTo = null)),
                ],
              ),
            ),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(8.0),
              child: Row(
                children: [
                  IconButton(
                    icon: _uploadingImage ? const SizedBox(height: 20, width: 20, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.image_outlined),
                    onPressed: _uploadingImage ? null : _pickAndSendImages,
                  ),
                  Expanded(
                    child: TextField(
                      controller: _messageController,
                      decoration: InputDecoration(hintText: 'Type a message...', border: OutlineInputBorder(borderRadius: BorderRadius.circular(24)), contentPadding: const EdgeInsets.symmetric(horizontal: 16)),
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