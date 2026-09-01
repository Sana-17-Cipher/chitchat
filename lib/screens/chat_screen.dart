import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:intl/intl.dart';
import 'package:image_picker/image_picker.dart';
import 'package:file_picker/file_picker.dart';
import 'package:url_launcher/url_launcher.dart';
import 'contact_info_screen.dart';

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
  late final Stream<Map<String, dynamic>?> _receiverStatusStream;
  late final RealtimeChannel _typingChannel;

  bool _otherUserTyping = false;
  bool _uploadingImage = false;
  bool _uploadingFile = false;
  bool _isBlockedByMe = false;
  bool _isBlockedByThem = false;
  Map<String, dynamic>? _replyingTo;
  Timer? _typingTimer;

  bool get _isBlocked => _isBlockedByMe || _isBlockedByThem;
  bool get _isUploading => _uploadingImage || _uploadingFile;

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

    _receiverStatusStream = supabase
        .from('profiles')
        .stream(primaryKey: ['id'])
        .eq('id', widget.receiverId)
        .map((rows) => rows.isNotEmpty ? rows.first : null);

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
      final myBlock = await supabase
          .from('blocked_users')
          .select()
          .eq('blocker_id', _currentUserId)
          .eq('blocked_id', widget.receiverId)
          .maybeSingle();
      final theirBlock = await supabase
          .from('blocked_users')
          .select()
          .eq('blocker_id', widget.receiverId)
          .eq('blocked_id', _currentUserId)
          .maybeSingle();
      if (mounted) {
        setState(() {
          _isBlockedByMe = myBlock != null;
          _isBlockedByThem = theirBlock != null;
        });
      }
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
          content: const Text('They won\'t be able to send you messages or see your online status anymore.'),
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
      debugPrint('SEND MESSAGE ERROR: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Message failed to send. Check your connection and try again.')),
        );
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
      await supabase.from('messages').insert({
        'sender_id': _currentUserId,
        'receiver_id': widget.receiverId,
        'image_urls': urls,
      });
    } catch (e) {
      debugPrint('IMAGE UPLOAD ERROR: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Failed to send images. Check your connection and try again.')),
        );
      }
    } finally {
      if (mounted) setState(() => _uploadingImage = false);
    }
  }

  Future<void> _pickAndSendFile() async {
    final result = await FilePicker.platform.pickFiles(withData: true);
    if (result == null || result.files.isEmpty) return;
    final picked = result.files.first;
    if (picked.bytes == null) return;

    setState(() => _uploadingFile = true);
    try {
      final path = 'files/$_currentUserId/${DateTime.now().millisecondsSinceEpoch}_${picked.name}';
      await supabase.storage.from('chat_images').uploadBinary(path, picked.bytes!, fileOptions: const FileOptions(upsert: false));
      final publicUrl = supabase.storage.from('chat_images').getPublicUrl(path);

      await supabase.from('messages').insert({
        'sender_id': _currentUserId,
        'receiver_id': widget.receiverId,
        'file_url': publicUrl,
        'file_name': picked.name,
      });
    } catch (e) {
      debugPrint('FILE UPLOAD ERROR: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Failed to send file. Check your connection and try again.')),
        );
      }
    } finally {
      if (mounted) setState(() => _uploadingFile = false);
    }
  }

  Future<void> _openFile(String url) async {
    final uri = Uri.parse(url);
    try {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Could not open file')));
      }
    }
  }

  void _showAttachOptions() {
    showModalBottomSheet(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.photo_outlined),
              title: const Text('Photo'),
              onTap: () {
                Navigator.pop(context);
                _pickAndSendImages();
              },
            ),
            ListTile(
              leading: const Icon(Icons.insert_drive_file_outlined),
              title: const Text('Document'),
              onTap: () {
                Navigator.pop(context);
                _pickAndSendFile();
              },
            ),
          ],
        ),
      ),
    );
  }

  IconData _fileIconFor(String? fileName) {
    final ext = (fileName ?? '').split('.').last.toLowerCase();
    switch (ext) {
      case 'pdf':
        return Icons.picture_as_pdf;
      case 'doc':
      case 'docx':
        return Icons.description;
      case 'xls':
      case 'xlsx':
        return Icons.table_chart;
      case 'ppt':
      case 'pptx':
        return Icons.slideshow;
      case 'zip':
      case 'rar':
        return Icons.folder_zip;
      default:
        return Icons.insert_drive_file;
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
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Failed to delete message. Check your connection.')),
          );
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

  String _formatLastSeen(String? lastSeenIso) {
    if (lastSeenIso == null) return '';
    final dt = DateTime.parse(lastSeenIso).toLocal();
    final diff = DateTime.now().difference(dt);
    if (diff.inMinutes < 1) return 'Last seen just now';
    if (diff.inMinutes < 60) return 'Last seen ${diff.inMinutes}m ago';
    if (diff.inHours < 24) return 'Last seen ${diff.inHours}h ago';
    if (diff.inDays < 7) return 'Last seen ${diff.inDays}d ago';
    return 'Last seen ${DateFormat('MMM d').format(dt)}';
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
        title: GestureDetector(
          onTap: () {
            Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => ContactInfoScreen(userId: widget.receiverId, username: widget.receiverUsername)),
            );
          },
          child: StreamBuilder<Map<String, dynamic>?>(
            stream: _receiverStatusStream,
            builder: (context, snapshot) {
              final data = snapshot.data;
              final isOnline = data?['online'] == true;
              String statusText;
              if (_isBlocked) {
                statusText = '';
              } else if (_otherUserTyping) {
                statusText = 'typing...';
              } else if (isOnline) {
                statusText = 'Online';
              } else {
                statusText = _formatLastSeen(data?['last_seen'] as String?);
              }
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(widget.receiverUsername),
                  if (statusText.isNotEmpty)
                    Text(statusText, style: TextStyle(fontSize: 12, fontStyle: _otherUserTyping ? FontStyle.italic : FontStyle.normal)),
                ],
              );
            },
          ),
        ),
        actions: [
          PopupMenuButton<String>(
            onSelected: (value) {
              if (value == 'block') _toggleBlock();
            },
            itemBuilder: (context) => [
              PopupMenuItem(
                value: 'block',
                child: ListTile(
                  leading: Icon(_isBlockedByMe ? Icons.person_add_outlined : Icons.block),
                  title: Text(_isBlockedByMe ? 'Unblock user' : 'Block user'),
                ),
              ),
            ],
          ),
        ],
      ),
      body: Column(
        children: [
          if (_isBlocked)
            Container(
              width: double.infinity,
              color: Colors.red.shade50,
              padding: const EdgeInsets.all(12),
              child: Column(
                children: [
                  Text(
                    _isBlockedByMe ? 'You blocked ${widget.receiverUsername}' : 'You can\'t message this user',
                    textAlign: TextAlign.center,
                  ),
                  if (_isBlockedByMe) TextButton(onPressed: _toggleBlock, child: const Text('Unblock')),
                ],
              ),
            ),
          Expanded(
            child: StreamBuilder<List<Map<String, dynamic>>>(
              stream: _messagesStream,
              builder: (context, snapshot) {
                if (snapshot.hasError) {
                  return const Center(
                    child: Padding(padding: EdgeInsets.all(24), child: Text('Couldn\'t load messages. Check your connection.', textAlign: TextAlign.center)),
                  );
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
                    final isDelivered = msg['delivered_at'] != null;
                    final time = DateTime.parse(msg['created_at']).toLocal();
                    final imageUrl = msg['image_url'] as String?;
                    final imageUrls = (msg['image_urls'] as List?)?.cast<String>();
                    final fileUrl = msg['file_url'] as String?;
                    final fileName = msg['file_name'] as String?;
                    final content = msg['content'] as String?;
                    final quoted = _findMessageById(messages, msg['reply_to_id'] as String?);
                    final hasImages = (imageUrls != null && imageUrls.isNotEmpty) || imageUrl != null;
                    final hasAttachment = hasImages || fileUrl != null;

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
                              child: Container(
                                margin: const EdgeInsets.symmetric(vertical: 4),
                                padding: hasImages ? const EdgeInsets.all(4) : const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
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
                                    if (imageUrls != null && imageUrls.isNotEmpty)
                                      _buildImageGrid(imageUrls)
                                    else if (imageUrl != null)
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
                                    if (fileUrl != null)
                                      InkWell(
                                        onTap: () => _openFile(fileUrl),
                                        child: Container(
                                          padding: const EdgeInsets.all(8),
                                          margin: hasImages ? const EdgeInsets.only(top: 6) : EdgeInsets.zero,
                                          decoration: BoxDecoration(color: Colors.white.withOpacity(0.5), borderRadius: BorderRadius.circular(8)),
                                          child: Row(
                                            mainAxisSize: MainAxisSize.min,
                                            children: [
                                              Icon(_fileIconFor(fileName), size: 28, color: Colors.black87),
                                              const SizedBox(width: 8),
                                              Flexible(
                                                child: Text(
                                                  fileName ?? 'File',
                                                  overflow: TextOverflow.ellipsis,
                                                  maxLines: 1,
                                                  style: const TextStyle(color: Colors.black87),
                                                ),
                                              ),
                                              const SizedBox(width: 4),
                                              const Icon(Icons.download_outlined, size: 18, color: Colors.black54),
                                            ],
                                          ),
                                        ),
                                      ),
                                    if (content != null && content.isNotEmpty)
                                      Padding(
                                        padding: hasAttachment ? const EdgeInsets.only(top: 6, left: 6, right: 6) : EdgeInsets.zero,
                                        child: Text(content, style: const TextStyle(color: Colors.black87)),
                                      ),
                                    Padding(
                                      padding: hasAttachment ? const EdgeInsets.only(top: 4, left: 6, right: 6, bottom: 2) : const EdgeInsets.only(top: 4),
                                      child: Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          Text(DateFormat('h:mm a').format(time), style: const TextStyle(fontSize: 10, color: Colors.black54)),
                                          if (isMe) ...[
                                            const SizedBox(width: 4),
                                            Icon((isRead || isDelivered) ? Icons.done_all : Icons.done, size: 14, color: isRead ? Colors.blue : Colors.black45),
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
          if (!_isBlocked) ...[
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
                          Text(_replyingTo!['sender_id'] == _currentUserId ? 'Replying to yourself' : 'Replying to ${widget.receiverUsername}', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
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
                      icon: _isUploading
                          ? const SizedBox(height: 20, width: 20, child: CircularProgressIndicator(strokeWidth: 2))
                          : const Icon(Icons.attach_file),
                      onPressed: _isUploading ? null : _showAttachOptions,
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