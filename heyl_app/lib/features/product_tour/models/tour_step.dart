enum TourStep {
  idle,
  welcome,
  searchBar,
  discoverCity,
  createSheet,
  yoursNav,
  profileMenu,
  done;

  int get stepNumber {
    switch (this) {
      case TourStep.searchBar:
        return 1;
      case TourStep.discoverCity:
        return 2;
      case TourStep.createSheet:
        return 3;
      case TourStep.yoursNav:
        return 4;
      case TourStep.profileMenu:
        return 5;
      case TourStep.welcome:
      case TourStep.idle:
      case TourStep.done:
        return 0;
    }
  }

  String get analyticsName {
    switch (this) {
      case TourStep.welcome:
        return 'welcome';
      case TourStep.searchBar:
        return 'search';
      case TourStep.discoverCity:
        return 'discover';
      case TourStep.createSheet:
        return 'create';
      case TourStep.yoursNav:
        return 'yours';
      case TourStep.profileMenu:
        return 'profile_menu';
      case TourStep.idle:
      case TourStep.done:
        return '';
    }
  }

  bool get isLastVisibleStep => this == TourStep.profileMenu;
}

enum TourAction { view, next, skip }
