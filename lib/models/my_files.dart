import 'package:flutter/material.dart';

class SingleValueInfo {
  final String?  title, totalStorage,unit;
  final int? numOfFiles, percentage;
  final Color? color;
  final PopupMenuItem? popMenu;
  final IconData? icon;

  SingleValueInfo({
    this.title,
    this.totalStorage,
    this.numOfFiles,
    this.percentage,
    this.color,
    this.unit,
    this.popMenu,
    this.icon,
  });
}

