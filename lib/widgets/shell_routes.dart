import 'package:flutter/widgets.dart';

/// Lets the main screens hear a pushed page closing: the shell gives the tab
/// bar back, and Today raises an alert it held while something sat on top.
final RouteObserver<ModalRoute<void>> shellRoutes =
    RouteObserver<ModalRoute<void>>();
