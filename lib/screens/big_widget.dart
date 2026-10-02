import 'package:flutter/material.dart';
import 'package:tomesdashboard/constants.dart';

class BigScreenWidget extends StatefulWidget {
  const BigScreenWidget({
    super.key,
    required this.widget,
  });
  final Widget widget;
  @override
  State<StatefulWidget> createState() => _BigScreenWidget();
}

class _BigScreenWidget extends State<BigScreenWidget> {
  
  @override
  Widget build(BuildContext context) {
    
    return SafeArea(
      child: Scaffold(
        appBar: AppBar(),
        body: Padding(
          padding: const EdgeInsets.all(defaultPadding),
          child:  LayoutBuilder(
          builder: (context,constrait) {
            return Row(
              children: [
                Expanded(child: widget.widget),
              ],
            );
            }
          ),
        ),
      ),
    );
  }
}