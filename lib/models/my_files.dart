import 'package:tomesdashboard/constants.dart';
import 'package:flutter/material.dart';

class SingleValueInfo {
  final String?  title, totalStorage,unit;
  final int? numOfFiles, percentage;
  final Color? color;
  final PopupMenuItem? drawer;
  final IconData? icon;

  SingleValueInfo({
    this.title,
    this.totalStorage,
    this.numOfFiles,
    this.percentage,
    this.color,
    this.unit,
    this.drawer,
    this.icon,
  });
}

