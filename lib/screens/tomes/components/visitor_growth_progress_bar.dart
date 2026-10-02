import 'package:flutter/material.dart';

class VisitorGrowthProgressBar extends StatelessWidget {
  const VisitorGrowthProgressBar({
    super.key,
    required this.title,
    required this.subTitle,
    required this.progress,
    required this.color,
  });

  final String title;
  final String subTitle;
  final double progress;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Column(
      spacing: 2,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [Text(title), Text( subTitle)],
        ),
        LinearProgressIndicator(
          value: progress,
          backgroundColor: Colors.grey.withAlpha(125),
          valueColor: AlwaysStoppedAnimation<Color>(color),
          minHeight: 8,
          borderRadius: BorderRadius.circular(8),
        ),
      ],
    );
  }
}
