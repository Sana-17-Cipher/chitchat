import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'screens/auth_screen.dart';
import 'screens/home_screen.dart';
import 'config.dart';
import 'package:firebase_core/firebase_core.dart';
import 'notification_service.dart';
final navigatorKey = GlobalKey<NavigatorState>();

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp();
  await Supabase.initialize(
    url: supabaseUrl,
    publishableKey: supabaseAnonKey,
  );

  Supabase.instance.client.auth.onAuthStateChange.listen((data) async {
    final event = data.event;
    final session = data.session;
    if ((event == AuthChangeEvent.signedIn || event == AuthChangeEvent.initialSession) && session != null) {
      await Supabase.instance.client.from('profiles').update({'online': true}).eq('id', session.user.id);
      await NotificationService.initialize();
    }
  });

  runApp(const ChitChatApp());
}

final supabase = Supabase.instance.client;

class ChitChatApp extends StatefulWidget {
  const ChitChatApp({super.key});

  @override
  State<ChitChatApp> createState() => _ChitChatAppState();
}

class _ChitChatAppState extends State<ChitChatApp> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final userId = supabase.auth.currentUser?.id;
    if (userId == null) return;

    if (state == AppLifecycleState.resumed) {
      supabase.from('profiles').update({'online': true}).eq('id', userId);
    } else if (state == AppLifecycleState.paused || state == AppLifecycleState.detached) {
      supabase.from('profiles').update({
        'online': false,
        'last_seen': DateTime.now().toIso8601String(),
      }).eq('id', userId);
    }
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      navigatorKey: navigatorKey,
      title: 'ChitChat',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        scaffoldBackgroundColor: const Color(0xFFFFFBF0),
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFFE8B93F),
          brightness: Brightness.light,
        ).copyWith(
          primary: const Color(0xFFE8B93F),
          onPrimary: Colors.black87,
          secondary: const Color(0xFFC9E4B0),
        ),
        appBarTheme: const AppBarTheme(
          backgroundColor: Color(0xFFF3D577),
          foregroundColor: Colors.black87,
          elevation: 0,
        ),
        filledButtonTheme: FilledButtonThemeData(
          style: FilledButton.styleFrom(
            backgroundColor: const Color(0xFFE8B93F),
            foregroundColor: Colors.black87,
          ),
        ),
      ),
      home: const AuthGate(),
    );
  }
}

class AuthGate extends StatelessWidget {
  const AuthGate({super.key});

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<AuthState>(
      stream: supabase.auth.onAuthStateChange,
      builder: (context, snapshot) {
        final session = supabase.auth.currentSession;
        if (session != null) {
          return const HomeScreen();
        }
        return const AuthScreen();
      },
    );
  }
}