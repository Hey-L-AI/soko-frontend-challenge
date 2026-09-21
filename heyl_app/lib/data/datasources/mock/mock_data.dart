import '../../models/models.dart';

/// Static mock data matching the Lovable prototype
class MockData {
  MockData._();

  // ============ USER ============
  static final mockUser = UserProfile(
    id: '123e4567-e89b-12d3-a456-426614174000',
    userId: '123e4567-e89b-12d3-a456-426614174000', // Now UUID (same as id)
    displayIdentifier: '+351912345678', // Phone number for display
    fullName: 'Alex',
    city: 'Lisbon',
    neighborhood: 'Anjos',
    country: 'Portugal',
    interests: ['music', 'food', 'wine', 'outdoors'],
    preferredLocale: 'pt-PT',
    role: UserRole.user,
    onboardingComplete: true,
    createdAt: DateTime.now().subtract(const Duration(days: 60)),
    updatedAt: DateTime.now(),
  );

  // ============ MESSAGE STARTERS ============
  // Mock personalized starters (15-20 items, matching what AI would generate)
  static final mockMessageStarters = [
    const MessageStarter(id: 'starter_01', text: "What's going on in Lisbon?"),
    const MessageStarter(id: 'starter_02', text: 'Find me a natural wine bar nearby'),
    const MessageStarter(id: 'starter_03', text: 'Any jazz nights this week?'),
    const MessageStarter(id: 'starter_04', text: 'Cozy Italian restaurants for a date'),
    const MessageStarter(id: 'starter_05', text: "What's happening this weekend?"),
    const MessageStarter(id: 'starter_06', text: 'Outdoor activities in Príncipe Real'),
    const MessageStarter(id: 'starter_07', text: 'Where can I find live music tonight?'),
    const MessageStarter(id: 'starter_08', text: 'Running clubs nearby'),
    const MessageStarter(id: 'starter_09', text: 'Vegetarian-friendly brunch spots'),
    const MessageStarter(id: 'starter_10', text: 'Best coffee shops to work from'),
    const MessageStarter(id: 'starter_11', text: 'Any food markets open today?'),
    const MessageStarter(id: 'starter_12', text: 'Rooftop bars with good views'),
    const MessageStarter(id: 'starter_13', text: 'Wine tasting events coming up'),
    const MessageStarter(id: 'starter_14', text: 'Quiet spots for a walk'),
    const MessageStarter(id: 'starter_15', text: 'Art exhibitions in Chiado'),
    const MessageStarter(id: 'starter_16', text: 'Late night food options'),
    const MessageStarter(id: 'starter_17', text: 'Yoga classes in Jardim da Estrela'),
    const MessageStarter(id: 'starter_18', text: 'Best petiscos near Anjos'),
  ];

  // ============ SESSIONS ============
  static final mockSessions = [
    // Today
    Session(
      sessionId: 'session_today_1',
      userId: mockUser.id,
      createdAt: DateTime.now().subtract(const Duration(hours: 2)),
      lastMessageAt: DateTime.now().subtract(const Duration(hours: 1)),
      channel: SessionChannel.web,
      title: 'Date night ideas in Anjos',
    ),
    Session(
      sessionId: 'session_today_2',
      userId: mockUser.id,
      createdAt: DateTime.now().subtract(const Duration(hours: 5)),
      lastMessageAt: DateTime.now().subtract(const Duration(hours: 4)),
      channel: SessionChannel.web,
      title: 'Running clubs nearby',
    ),
    // Yesterday
    Session(
      sessionId: 'session_yesterday_1',
      userId: mockUser.id,
      createdAt: DateTime.now().subtract(const Duration(days: 1, hours: 3)),
      lastMessageAt: DateTime.now().subtract(const Duration(days: 1, hours: 2)),
      channel: SessionChannel.web,
      title: 'Weekend brunch spots',
    ),
    // This week
    Session(
      sessionId: 'session_week_1',
      userId: mockUser.id,
      createdAt: DateTime.now().subtract(const Duration(days: 3)),
      lastMessageAt: DateTime.now().subtract(const Duration(days: 3)),
      channel: SessionChannel.web,
      title: 'Live music venues',
    ),
    Session(
      sessionId: 'session_week_2',
      userId: mockUser.id,
      createdAt: DateTime.now().subtract(const Duration(days: 5)),
      lastMessageAt: DateTime.now().subtract(const Duration(days: 5)),
      channel: SessionChannel.web,
      title: 'Coworking spaces in Chiado',
    ),
    // Older
    Session(
      sessionId: 'session_older_1',
      userId: mockUser.id,
      createdAt: DateTime.now().subtract(const Duration(days: 14)),
      lastMessageAt: DateTime.now().subtract(const Duration(days: 14)),
      channel: SessionChannel.web,
      title: 'Art galleries in Chiado',
    ),
  ];

  // ============ EVENTS ============
  static final mockEvents = [
    Event(
      id: 'event_1',
      title: 'Jazz Night at Hot Clube',
      category: 'Music',
      isActive: true,
      isPublic: true,
      description: 'Live jazz performance featuring local artists',
      imageUrl: 'https://images.unsplash.com/photo-1514320291840-2e0a9bf2a9ae?w=400',
      startDate: DateTime.now().add(const Duration(days: 2)),
      venueName: 'Hot Clube de Portugal',
      city: 'Lisbon',
    ),
    Event(
      id: 'event_2',
      title: 'Wine Tasting: Portuguese Reds',
      category: 'Food & Drink',
      isActive: true,
      isPublic: true,
      description: 'Explore the best Portuguese red wines',
      imageUrl: 'https://images.unsplash.com/photo-1510812431401-41d2bd2722f3?w=400',
      startDate: DateTime.now().add(const Duration(days: 5)),
      venueName: 'Wine Bar do Castelo',
      city: 'Lisbon',
    ),
    Event(
      id: 'event_3',
      title: 'Fado Night',
      category: 'Music',
      isActive: true,
      isPublic: true,
      description: 'Traditional Portuguese fado performance',
      imageUrl: 'https://images.unsplash.com/photo-1493225457124-a3eb161ffa5f?w=400',
      startDate: DateTime.now().add(const Duration(days: 1)),
      venueName: 'Tasca do Chico',
      city: 'Lisbon',
    ),
    Event(
      id: 'event_4',
      title: 'Outdoor Yoga in Jardim da Estrela',
      category: 'Wellness',
      isActive: true,
      isPublic: true,
      description: 'Morning yoga session in the park',
      imageUrl: 'https://images.unsplash.com/photo-1544367567-0f2fcb009e0b?w=400',
      startDate: DateTime.now().add(const Duration(days: 3)),
      venueName: 'Jardim da Estrela',
      city: 'Lisbon',
    ),
  ];

  // ============ VENUES ============
  static final mockVenues = [
    const Venue(
      id: 'venue_1',
      name: 'Natural Wine Bar',
      city: 'Lisbon',
      description: 'Cozy wine bar with natural wines from Portugal',
      imageUrl: 'https://images.unsplash.com/photo-1510812431401-41d2bd2722f3?w=400',
      neighborhood: 'Anjos',
      tags: ['Wine', 'Cozy', 'Natural'],
    ),
    const Venue(
      id: 'venue_2',
      name: 'Rooftop Restaurant',
      city: 'Lisbon',
      description: 'Stunning views of the city with Mediterranean cuisine',
      imageUrl: 'https://images.unsplash.com/photo-1517248135467-4c7edcad34c4?w=400',
      neighborhood: 'Chiado',
      tags: ['Views', 'Romantic', 'Mediterranean'],
    ),
    const Venue(
      id: 'venue_3',
      name: 'Mercado da Ribeira',
      city: 'Lisbon',
      description: 'Historic market with food stalls and restaurants',
      imageUrl: 'https://images.unsplash.com/photo-1555396273-367ea4eb4db5?w=400',
      neighborhood: 'Cais do Sodré',
      tags: ['Food', 'Market', 'Casual'],
    ),
    const Venue(
      id: 'venue_4',
      name: 'Jardim Botânico',
      city: 'Lisbon',
      description: 'Beautiful botanical garden in the city center',
      imageUrl: 'https://images.unsplash.com/photo-1585320806297-9794b3e4eeae?w=400',
      neighborhood: 'Príncipe Real',
      tags: ['Nature', 'Peaceful', 'Photography'],
    ),
  ];

  // ============ PLACE SUGGESTIONS (for chat) ============
  static final mockItemSuggestions = [
    ItemSuggestion(
      id: 'place_1',
      name: 'Natural Wine Bar',
      imageUrl: 'https://images.unsplash.com/photo-1510812431401-41d2bd2722f3?w=400',
      tags: ['Wine', 'Cozy', 'Anjos'],
      type: 'place',
      venueId: 'venue_1',
    ),
    ItemSuggestion(
      id: 'place_2',
      name: 'Rooftop Restaurant',
      imageUrl: 'https://images.unsplash.com/photo-1517248135467-4c7edcad34c4?w=400',
      tags: ['Views', 'Romantic'],
      type: 'place',
      venueId: 'venue_2',
    ),
    ItemSuggestion(
      id: 'place_3',
      name: 'Jazz Night at Hot Clube',
      imageUrl: 'https://images.unsplash.com/photo-1514320291840-2e0a9bf2a9ae?w=400',
      tags: ['Music', 'Live', 'Jazz'],
      type: 'event',
      eventId: 'event_1',
    ),
  ];

  // ============ SAVED ITEMS ============
  static final mockSavedItems = [
    SavedItem(
      savedId: 'saved_1',
      type: SavedItemType.event,
      eventId: 'event_1',
      createdAt: DateTime.now().subtract(const Duration(days: 2)),
      title: 'Jazz Night at Hot Clube',
      imageUrl: 'https://images.unsplash.com/photo-1514320291840-2e0a9bf2a9ae?w=400',
      category: 'Music',
    ),
    SavedItem(
      savedId: 'saved_2',
      type: SavedItemType.place,
      venueId: 'venue_1',
      createdAt: DateTime.now().subtract(const Duration(days: 5)),
      title: 'Natural Wine Bar',
      imageUrl: 'https://images.unsplash.com/photo-1510812431401-41d2bd2722f3?w=400',
      category: 'Wine',
    ),
  ];

  // ============ USER MEMORY ============
  static final mockUserMemory = UserMemory(
    id: mockUser.id,
    userId: mockUser.id, // Use the UUID (id), not the old userId format
    fullName: mockUser.fullName,
    memoryText: 'Alex lives in Lisbon and enjoys jazz, wine, and outdoor activities.',
    memoryKeyFacts: [
      'Lives in Anjos, Lisbon',
      'Loves natural wine bars',
      'Prefers cozy, intimate spots over loud venues',
      'Italian food is your go-to for date nights',
      'Vegetarian-friendly but not strictly vegetarian',
    ],
    memoryConversationCount: 12,
    memoryLastUpdated: DateTime.now().subtract(const Duration(days: 1)),
    memoryConfidenceNotes: 'High confidence on location and preferences',
    city: 'Lisbon',
    createdAt: mockUser.createdAt,
    classificationName: 'Alex',
    classificationHomeLocation: 'Anjos, Lisbon',
    classificationCurrentLocation: 'Príncipe Real',
    classificationPrimaryLanguage: 'pt-PT',
    classificationInterestTags: ['music', 'wine', 'food', 'outdoors'],
    classificationPersonaTags: ['local_explorer', 'foodie'],
    classificationCommunicationStyle: 'casual',
    classificationEngagementTier: 'high',
    classificationChurnRisk: 'low',
    classificationConfidence: 0.85,
    classificationLastUpdated: DateTime.now().subtract(const Duration(days: 1)),
  );

  // ============ MEMORY ITEMS (for display) ============
  static final mockMemoryItems = [
    // Location
    MemoryItem(
      text: 'You live in Anjos, Lisbon',
      category: MemoryCategory.location,
      timestamp: DateTime.now().subtract(const Duration(days: 14)),
    ),
    MemoryItem(
      text: 'Your favorite neighborhood is Príncipe Real',
      category: MemoryCategory.location,
      timestamp: DateTime.now().subtract(const Duration(days: 30)),
    ),
    MemoryItem(
      text: 'You work near Marquês de Pombal',
      category: MemoryCategory.location,
      timestamp: DateTime.now().subtract(const Duration(days: 21)),
    ),
    // Preferences
    MemoryItem(
      text: 'You love natural wine bars',
      category: MemoryCategory.preferences,
      timestamp: DateTime.now().subtract(const Duration(days: 7)),
    ),
    MemoryItem(
      text: 'You prefer cozy, intimate spots over loud places',
      category: MemoryCategory.preferences,
      timestamp: DateTime.now().subtract(const Duration(days: 14)),
    ),
    MemoryItem(
      text: 'Italian food is your go-to for date nights',
      category: MemoryCategory.preferences,
      timestamp: DateTime.now().subtract(const Duration(days: 3)),
    ),
    MemoryItem(
      text: "You're vegetarian-friendly but not strictly vegetarian",
      category: MemoryCategory.preferences,
      timestamp: DateTime.now().subtract(const Duration(days: 21)),
    ),
    // Feedback
    MemoryItem(
      text: 'You liked the recommendation for Hot Clube',
      category: MemoryCategory.feedback,
      timestamp: DateTime.now().subtract(const Duration(days: 2)),
    ),
  ];

  // ============ LOCATION ============
  static final mockLocation = LocationSnapshot(
    lat: 38.7223,
    lon: -9.1393,
    accuracyM: 25,
    source: LocationSource.deviceGps,
    capturedAt: DateTime.now(),
  );

  // ============ SUPPORT INFO ============
  static const mockSupportInfo = SupportInfo(
    email: 'support@soko.fyi',
    whatsapp: null,
    hours: 'Monday - Friday, 9:00 - 18:00 WET',
    responseTime: 'within 24 hours',
  );
}
