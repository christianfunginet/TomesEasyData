import 'package:flutter/material.dart';

class MenuAppController extends ChangeNotifier {
  int _selectedIndex = 0;
  int get selectedIndex => _selectedIndex;

  void selectMenu(int index) {
    _selectedIndex = index;
    notifyListeners();
  }
}
