# ChitChat

ChitChat is a real-time messaging application built with Flutter and Supabase, developed as a hands-on project to understand flutter development

Rather than treating the project as only a UI exercise, ChitChat is being developed to explore how authentication, real-time data, database security, storage, state changes, and user interactions work together in a complete application.

# Concepts Explored

* Real-Time Systems — Live message delivery using Supabase Realtime without polling or manual refresh.
* Database Design — Structured relationships between users, conversations, messages, groups, and profiles using PostgreSQL.
* Row Level Security — Database-level authorization to ensure users can only access permitted conversations and perform permitted actions.
* State Management — Handling unread messages, read receipts, message states, conversation updates, and UI changes.
* File Storage — Uploading and referencing profile pictures and message images through Supabase Storage.
* Messaging Interactions — Replies, message deletion, conversation deletion, date grouping, and contextual message actions.
* Error & Network Handling — Designing the application around changing connectivity and asynchronous operations.

## Current Features

* Email and password authentication
* User profiles with editable username and profile picture
* Real-time one-to-one messaging
* Real-time group messaging
* Conversation list with last message, timestamp, and unread count
* User search for starting new conversations
* Typing indicators using Supabase Broadcast
* Read receipts
* Image sharing
* Message reply with quoted message preview
* Message deletion
* Swipe-to-delete conversations from the Home screen
* Date-based message grouping
* In-app notifications with direct chat navigation
* User blocking
* Group creator controls
* Row Level Security (RLS) for protected database access

## Tech Stack

* **Flutter** — Mobile application and UI
* **Supabase Auth** — Authentication
* **PostgreSQL** — Application data
* **Supabase Realtime** — Live message updates
* **Supabase Storage** — Images and profile pictures
* **Supabase Broadcast** — Typing indicators
* **Row Level Security** — Database-level access control

## Architecture

ChitChat communicates directly with Supabase without a custom backend server. Messages are stored in PostgreSQL and delivered to active conversations through Supabase Realtime subscriptions. Access to conversations and messages is controlled using database-level RLS policies.

## Project Status

ChitChat is currently under active development. The core messaging system is functional, while additional features, reliability improvements, UI refinement, and testing are ongoing.

## Planned Development

* Improved messaging UI and overall application polish
* Enhanced group management
* Push notifications
* Improved network and reconnection handling
* Local message persistence and synchronization
* Cellular-based messaging fallback for supported Android devices
* Additional privacy and safety controls
* Performance optimization and testing

## Platform

Currently developed and tested for Android.
