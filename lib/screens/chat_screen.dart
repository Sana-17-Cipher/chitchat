import 'dart:async';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:intl/intl.dart';
import 'package:image_picker/image_picker.dart';

class ChatScreen extends StatefulWidget {
  final String receiverId;
  final String receiverUsername;

  const ChatScreen({super.key, required this.receiverId, required this.receiverUsername});

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final supabase = Supabase.instance.client;
  final _messageController = TextEditingController();
  final _scrollController = ScrollController();
  final ImagePicker _picker = ImagePicker();
  late final String _currentUserId;
  late final Stream<List<Map<String, dynamic>>> _messagesStream;
  late final RealtimeChannel _typingChannel;

  bool _otherUserTyping = false;
  bool _uploadingImage = false;
  bool _isBlockedByMe = false;
  Map<String, dynamic>? _replyingTo;
  Timer? _typingTimer;

  @override
  void initState() {
    super.initState();
    _currentUserId = supabase.auth.currentUser!.id;

    _messagesStream = supabase
        .from('messages')
        .stream(primaryKey: ['id'])
        .order('created_at')
        .map((rows) {
      final filtered = rows.where((row) {
        final sender = row['sender_id'];
        final receiver = row['receiver_id'];
        return (sender == _currentUserId && receiver == widget.receiverId) ||
            (sender == widget.receiverId && receiver == _currentUserId);
      }).toList();
      filtered.sort((a, b) => DateTime.parse(a['created_at']).compareTo(DateTime.parse(b['created_at'])));
      return filtered;
    });

    final ids = [_currentUserId, widget.receiverId]..sort();
    _typingChannel = supabase.channel('typing_${ids.join('_')}');
    _typingChannel.onBroadcast(
      event: 'typing',
      callback: (payload) {
        if (payload['user_id'] == widget.receiverId) {
          setState(() => _otherUserTyping = payload['is_typing'] as bool);
        }
      },
    ).subscribe();

    _checkBlockStatus();
  }

  Future<void> _checkBlockStatus() async {
    try {
      final data = await supabase.from('blocked_users').select().eq('blocker_id', _currentUserId).eq('blocked_id', widget.receiverId).maybeSingle();
      if (mounted) setState(() => _isBlockedByMe = data != null);
    } catch (e) {
      debugPrint('Failed to check block status: $e');
    }
  }

  Future<void> _toggleBlock() async {
    if (_isBlockedByMe) {
      await supabase.from('blocked_users').delete().eq('blocker_id', _currentUserId).eq('blocked_id', widget.receiverId);
      if (mounted) setState(() => _isBlockedByMe = false);
    } else {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text('Block ${widget.receiverUsername}?'),
          content: const Text('They won\'t be able to send you messages anymore.'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
            TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('Block')),
          ],
        ),
      );
      if (confirmed == true) {
        await supabase.from('blocked_users').insert({'blocker_id': _currentUserId, 'blocked_id': widget.receiverId});
        if (mounted) setState(() => _isBlockedByMe = true);
      }
    }
  }

  void _onTextChanged(String text) {
    _typingChannel.sendBroadcastMessage(event: 'typing', payload: {'user_id': _currentUserId, 'is_typing': text.isNotEmpty});
    _typingTimer?.cancel();
    if (text.isNotEmpty) {
      _typingTimer = Timer(const Duration(seconds: 3), () {
        _typingChannel.sendBroadcastMessage(event: 'typing', payload: {'user_id': _currentUserId, 'is_typing': false});
      });
    }
  }

  Future<void> _markMessagesAsRead(List<Map<String, dynamic>> messages) async {
    final unreadIds = messages.where((m) => m['receiver_id'] == _currentUserId && m['is_read'] != true).map((m) => m['id']).toList();
    if (unreadIds.isEmpty) return;
    try {
      await supabase.from('messages').update({'is_read': true}).inFilter('id', unreadIds);
    } catch (e) {
      debugPrint('Failed to mark messages as read: $e');
    }
  }

  Future<void> _sendMessage() async {
    final text = _messageController.text.trim();
    if (text.isEmpty) return;

    _typingTimer?.cancel();
    _typingChannel.sendBroadcastMessage(event: 'typing', payload: {'user_id': _currentUserId, 'is_typing': false});

    final replyToId = _replyingTo?['id'];

    try {
      await supabase.from('messages').insert({
        'sender_id': _currentUserId,
        'receiver_id': widget.receiverId,
        'content': text,
        if (replyToId != null) 'reply_to_id': replyToId,
      });
      _messageController.clear();
      setState(() => _replyingTo = null);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Message failed to send. Check your connection and try again.')));
      }
    }
  }

  Future<void> _pickAndSendImage() async {
    final XFile? picked = await _picker.pickImage(source: ImageSource.gallery, maxWidth: 1600, imageQuality: 80);
    if (picked == null) return;
    setState(() => _uploadingImage = true);
    try {
      final bytes = await picked.readAsBytes();
      final ext = picked.name.contains('.') ? picked.name.split('.').last : 'jpg';
      final path = '$_currentUserId/${DateTime.now().millisecondsSinceEpoch}.$ext';
      await supabase.storage.from('chat_images').uploadBinary(path, bytes, fileOptions: const FileOptions(upsert: false));
      final publicUrl = supabase.storage.from('chat_images').getPublicUrl(path);
      await supabase.from('messages').insert({'sender_id': _currentUserId, 'receiver_id': widget.receiverId, 'image_url': publicUrl});
    } catch (e) {
      debugPrint('IMAGE UPLOAD ERROR: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Failed to send image. Check your connection and try again.')));
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
        await supabase.from('messages').delete().eq('id', messageId);
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Failed to delete message. Check your connection.')));
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
    _typingTimer?.cancel();
    supabase.removeChannel(_typingChannel);
    _messageController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(widget.receiverUsername),
            if (_otherUserTyping) const Text('typing...', style: TextStyle(fontSize: 12, fontStyle: FontStyle.italic)),
          ],
        ),
        actions: [
          PopupMenuButton<String>(
            onSelected: (value) {
              if (value == 'block') _toggleBlock();
            },
            itemBuilder: (context) => [
              PopupMenuItem(
                value: 'block',
                child: ListTile(leading: Icon(_isBlockedByMe ? Icons.person_add_outlined : Icons.block), title: Text(_isBlockedByMe ? 'Unblock user' : 'Block user')),
              ),
            ],
          ),
        ],
      ),
      body: Column(
        children: [
          if (_isBlockedByMe)
            Container(
              width: double.infinity,
              color: Colors.red.shade50,
              padding: const EdgeInsets.all(12),
              child: Column(
                children: [
                  Text('You blocked ${widget.receiverUsername}', textAlign: TextAlign.center),
                  TextButton(onPressed: _toggleBlock, child: const Text('Unblock')),
                ],
              ),
            ),
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
                  return const Center(child: Text('Say hi 👋'));
                }

                WidgetsBinding.instance.addPostFrameCallback((_) {
                  _markMessagesAsRead(messages);
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
                    final isRead = msg['is_read'] == true;
                    final time = DateTime.parse(msg['created_at']).toLocal();
                    final imageUrl = msg['image_url'] as String?;
                    final content = msg['content'] as String?;
                    final quoted = _findMessageById(messages, msg['reply_to_id'] as String?);

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
                            direction: isMe ? DismissDirection.endToStart : DismissDirection.startToEnd,
                            confirmDismiss: (direction) async {
                              if (isMe) {
                                _confirmDelete(msg['id']);
                              } else {
                                setState(() => _replyingTo = msg);
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
                              child: Container(
                                margin: const EdgeInsets.symmetric(vertical: 4),
                                padding: imageUrl != null ? const EdgeInsets.all(4) : const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                                constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.7),
                                decoration: BoxDecoration(
                                  color: isMe ? const Color(0xFFC9E4B0) : const Color(0xFFE0D4F0),
                                  borderRadius: BorderRadius.circular(16),
                                ),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
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
                                    if (imageUrl != null)
                                      GestureDetector(
                                        onTap: () => _openFullImage(imageUrl),
                                        child: ClipRRect(
                                          borderRadius: BorderRadius.circular(12),
                                          child: Image.network(
                                            imageUrl,
                                            fit: BoxFit.cover,
                                            loadingBuilder: (context, child, progress) {
                                              if (progress == null) return child;
                                              return const SizedBox(height: 150, width: 150, child: Center(child: CircularProgressIndicator()));
                                            },
                                            errorBuilder: (context, error, stackTrace) => const SizedBox(height: 100, width: 100, child: Center(child: Icon(Icons.broken_image_outlined))),
                                          ),
                                        ),
                                      ),
                                    if (content != null && content.isNotEmpty)
                                      Padding(
                                        padding: imageUrl != null ? const EdgeInsets.only(top: 6, left: 6, right: 6) : EdgeInsets.zero,
                                        child: Text(content, style: const TextStyle(color: Colors.black87)),
                                      ),
                                    Padding(
                                      padding: imageUrl != null ? const EdgeInsets.only(top: 4, left: 6, right: 6, bottom: 2) : const EdgeInsets.only(top: 4),
                                      child: Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          Text(DateFormat('h:mm a').format(time), style: const TextStyle(fontSize: 10, color: Colors.black54)),
                                          if (isMe) ...[
                                            const SizedBox(width: 4),
                                            Icon(isRead ? Icons.done_all : Icons.done, size: 14, color: isRead ? Colors.blue : Colors.black45),
                                          ],
                                        ],
                                      ),
                                    ),
                                  ],
                                ),
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
          if (!_isBlockedByMe) ...[
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
                            _replyingTo!['sender_id'] == _currentUserId ? 'Replying to yourself' : 'Replying to ${widget.receiverUsername}',
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
                      onPressed: _uploadingImage ? null : _pickAndSendImage,
                    ),
                    Expanded(
                      child: TextField(
                        controller: _messageController,
                        onChanged: _onTextChanged,
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
        ],
      ),
    );
  }
}