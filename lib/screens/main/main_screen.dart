import 'package:file_picker/file_picker.dart';
import 'package:tomesdashboard/chart_page.dart';
import 'package:tomesdashboard/dashboard_page.dart';
import 'package:tomesdashboard/responsive.dart';
import 'package:tomesdashboard/screens/dashboard/dashboard_screen.dart';
import 'package:flutter/material.dart';

// import 'package:provider/provider.dart';

import 'components/side_menu.dart';

class MainScreen extends StatefulWidget {
  final String title;
  final PlatformFile file;
  const MainScreen({super.key, required this.file,required this.title});

  @override
  State<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen> {
  // This widget is the home page of your application. It is stateful, meaning
  
  int num=0;
  @override
  Widget build(BuildContext context) {
    List<Widget> pages=[
      DashBoardPage(file: widget.file, title: widget.title),
      ChartPage()
    ];
    return Scaffold(
      // key: context.read<MenuAppController>().scaffoldKey,
      drawer: SideMenu( onTap: (int selected) {
        setState(() {
            num=selected;          
        });
      },),
      body: SafeArea(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // We want this side menu only for large screen
            if (Responsive.isDesktop(context))
              Expanded(
                // default flex = 1
                // and it takes 1/6 part of the screen
                child: SideMenu(onTap: (selected) {
                  setState(() {
                      num=selected;          
                  });
                  
                },),
              ),
            Expanded(
              // It takes 5/6 part of the screen
              flex: 5,
              child: pages[num],
            ),
          ],
        ),
      ),
    );
  }
}
