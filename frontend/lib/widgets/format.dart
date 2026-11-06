/// Money and month names, written the same way on every screen.
const monthShort = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
const monthLong = ['January', 'February', 'March', 'April', 'May', 'June', 'July', 'August', 'September',
  'October', 'November', 'December'];

/// 56400 -> "56,400"; -6400 -> "−6,400" (a real minus sign).
String money(num v) {
  final s = v.abs().round().toString().replaceAllMapped(RegExp(r'\B(?=(\d{3})+(?!\d))'), (m) => ',');
  return v < 0 ? '−$s' : s;
}

/// 56400 -> "KES 56,400".
String kesAmount(num v) => v < 0 ? '−KES ${money(-v)}' : 'KES ${money(v)}';

/// 65000 -> "65k" for chart labels.
String compact(num v) => v.abs() >= 1000 ? '${(v / 1000).round()}k' : v.round().toString();
