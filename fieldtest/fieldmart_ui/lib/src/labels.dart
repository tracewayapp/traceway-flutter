/// The fixed UI texts of `shared/labels.json`, verbatim: the journey's
/// checkpoints expect them on screen. `test/labels_test.dart` checks that
/// this file and the shared file agree.
library;

abstract final class L {
  static const appName = 'Fieldmart';

  // nav
  static const navHome = 'Home';
  static const navMarkets = 'Markets';
  static const navFeed = 'Feed';
  static const navCheckout = 'Checkout';
  static const navMore = 'More';
  static const navBack = 'Back';

  // home
  static const homeTitle = 'Fieldmart';
  static const homeSearch = 'Search Fieldmart';
  static const homeDeals = "Today's deals";
  static const homeGrid = 'Popular now';
  static const homeNew = 'New';
  static const homeSale = 'Sale';
  static String homeReviews(int n) => '($n)';

  // product
  static String galleryCounter(int i, int total) => '$i / $total';
  static const readMore = 'Read more';
  static const readLess = 'Show less';
  static const size = 'Size';
  static const colour = 'Colour';
  static String quantity(int n) => 'Qty $n';
  static String stock(int n) => 'In stock: $n';
  static const reviews = 'Reviews';
  static const helpful = 'Helpful';
  static const add = 'Add to cart';
  static const added = 'Added to cart';

  // markets
  static const marketsTitle = 'Markets';
  static String polls(int n) => 'Polls $n';
  static const timeframes = ['1H', '1D', '1W', '1M', '1Y'];
  static const watchlist = 'Watchlist';
  static const orderBook = 'Order book';
  static const openBook = 'Order book';
  static const bids = 'Bids';
  static const asks = 'Asks';
  static const close = 'Close';

  // feed
  static const feedTitle = 'Activity';
  static const jumpEnd = 'Jump to end';
  static const jumpStart = 'Jump to start';
  static const goTo = 'Go to row';
  static const go = 'Go';
  static const refresh = 'Refresh';
  static String week(int n) => 'Week $n';

  // checkout
  static const checkoutTitle = 'Checkout';
  static const sections = ['Contact', 'Delivery', 'Payment', 'Review'];
  static const name = 'Full name';
  static const email = 'Email';
  static const phone = 'Phone';
  static const account = 'Create account';
  static const password = 'Password';
  static const address = 'Address';
  static const city = 'City';
  static const postcode = 'Postcode';
  static const country = 'Country';
  static const countryPicker = 'Choose country';
  static const date = 'Delivery date';
  static const datePicker = 'Choose delivery date';
  static const window = 'Delivery window';
  static const windows = ['Morning', 'Afternoon', 'Evening'];
  static const door = 'Leave at door';
  static const gift = 'Gift wrap';
  static const giftNote = 'Gift note';
  static const card = 'Card number';
  static const expiry = 'Expiry';
  static const cvv = 'CVV';
  static const cardName = 'Name on card';
  static const saveCard = 'Save card';
  static const tip = 'Tip';
  static String tipValue(int n) => '$n%';
  static const promo = 'Promo code';
  static const summary = 'Order summary';
  static const loyalty = 'Loyalty number';
  static const terms = 'Terms and conditions';
  static const agree = 'I agree';
  static const menu = 'Delivery instructions';
  static const menuItems = ['Ring the bell', 'Call on arrival', 'Leave with a neighbour', 'No instructions'];
  static const edit = 'Edit items';
  static const done = 'Done';
  static const rating = 'How was checkout?';
  static const notes = 'Notes';
  static const place = 'Place order';
  static const success = 'Order placed';
  static String successDetail(String order) => 'Your order number is $order';

  // search
  static const searchTitle = 'Search';
  static const searchField = 'Search products';
  static const recent = 'Recent searches';
  static const empty = 'No results';

  // more
  static const moreTitle = 'More';
  static const diagnostics = 'Diagnostics';

  // diag
  static const diagTitle = 'Diagnostics';
  static const diagRun = 'Run';
  static const diagVariant = 'Variant';
  static const diagScenario = 'Scenario';
  static const diagBuild = 'Build';
  static const diagSession = 'Session';
  static const diagButtons = {
    'fm-diag-handled': 'Report handled error',
    'fm-diag-unhandled': 'Throw unhandled error',
    'fm-diag-reject': 'Unhandled rejection',
    'fm-diag-hang': 'Block main thread',
    'fm-diag-logs': 'Write 1,000 log lines',
    'fm-diag-http500': 'Request returning 500',
    'fm-diag-slow': 'Slow request',
    'fm-diag-event': 'Send custom event',
    'fm-diag-message': 'Send message',
  };

  /// `$104.00` from 10400 cents (shared/fixtures-api.md).
  static String price(int cents) {
    final negative = cents < 0;
    final abs = negative ? -cents : cents;
    return '${negative ? '-' : ''}\$${abs ~/ 100}.${(abs % 100).toString().padLeft(2, '0')}';
  }
}
