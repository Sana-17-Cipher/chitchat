import 'package:flutter/material.dart';
import 'chats_tab.dart';
import 'groups_tab.dart';
import 'profile_tab.dart';
import 'create_group_screen.dart';
import 'new_chat_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  int _selectedIndex = 0;
  static const _titles = ['ChitChat', 'Groups', 'Profile'];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_titles[_selectedIndex]),
        actions: [
          if (_selectedIndex == 1)
            IconButton(
              icon: const Icon(Icons.group_add_outlined),
              tooltip: 'New group',
              onPressed: () {
                Navigator.push(context, MaterialPageRoute(builder: (_) => const CreateGroupScreen()));
              },
            ),
        ],
      ),
      body: IndexedStack(
        index: _selectedIndex,
        children: const [
          ChatsTab(),
          GroupsTab(),
          ProfileTab(),
        ],
      ),
      floatingActionButton: _selectedIndex == 0
          ? FloatingActionButton(
        onPressed: () {
          Navigator.push(context, MaterialPageRoute(builder: (_) => const NewChatScreen()));
        },
        child: const Icon(Icons.chat),
      )
          : null,
      bottomNavigationBar: NavigationBar(
        selectedIndex: _selectedIndex,
        onDestinationSelected: (index) => setState(() => _selectedIndex = index),
        destinations: const [
          NavigationDestination(icon: Icon(Icons.chat_bubble_outline), selectedIcon: Icon(Icons.chat_bubble), label: 'Chats'),
          NavigationDestination(icon: Icon(Icons.group_outlined), selectedIcon: Icon(Icons.group), label: 'Groups'),
          NavigationDestination(icon: Icon(Icons.person_outline), selectedIcon: Icon(Icons.person), label: 'Profile'),
        ],
      ),
    );
  }
}