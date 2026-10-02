
import 'package:flutter/material.dart';
import 'package:tomesdashboard/constants.dart';

class SideMenu extends StatelessWidget {
  final int selected;
  final void Function(int ) onTap;

  const SideMenu({
    super.key,
    required this.onTap,
    required this.selected,
  });

  @override
  Widget build(BuildContext context) {
    return Drawer(
      backgroundColor:  Theme.of(context).splashColor,
        
      child: ListView(
        children: [
          DrawerHeader(
            child: Padding(
              padding: const EdgeInsets.only(left: 12.0),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text("Tomes"),
                  Text("Easy"),
                  Text("Data"),
                ],
              ),
            ),
          ),
          
          DrawerListTile(
            selected: selected==0,
            
            title: "Dashboard",
            icon: Icons.dashboard,
            color: Theme.of(context).primaryColor,
            press: () {
              onTap.call(0);
            
            },
          ),
          DrawerListTile(
            selected: selected==1,
            
            title: "Components",
            icon: Icons.bar_chart,
            color: Theme.of(context).primaryColor,
            press: () {
                onTap.call(1);
            },
          ),
          
          DrawerListTile(
            selected: selected==2,
            
            title: "Protocols",
            icon: Icons.article_outlined,
            color: Theme.of(context).primaryColor,
            press: () {
               onTap.call(2);
            },
          ),
          DrawerListTile(
            selected: selected==3,
            
            title: "Alarms",
            icon: Icons.notifications,
            color: Theme.of(context).primaryColor,
            press: () {
              onTap.call(3);
          
            },
          ),
          DrawerListTile(
            selected: selected==4,
            title: "Users",
            icon: Icons.person,
            color: Theme.of(context).primaryColor,
            press: () {
              onTap.call(4);
        
            },
          ),
          DrawerListTile(
            selected: selected==5,
            title: "Settings",
            icon: Icons.settings,
            color: Theme.of(context).primaryColor,
            press: () {
              onTap.call(5);
  
            },
          ),
        ],
      ),
    );
  }
}

class DrawerListTile extends StatelessWidget {
  const DrawerListTile({
    super.key,
    // For selecting those three line once press "Command+D"
    required this.title,
    required this.icon,
    required this.press,
    required this.color,
    required this.selected,

  });

  final bool selected;
  final String title;
  final IconData icon;
  final Color color;
  final VoidCallback press;

  @override
  Widget build(BuildContext context) {
    return Container(
      color:selected? Theme.of(context).primaryColor.withAlpha(150) :null ,
      child: ListTile(
        selected: selected,
        selectedColor: Theme.of(context).secondaryHeaderColor,
        onTap: press,
        horizontalTitleGap: 6.0,
        leading: Container(
          padding: EdgeInsets.all(defaultPadding * 0.5),
          height: 40,
          width: 40,
          decoration: BoxDecoration(
            borderRadius: const BorderRadius.all(Radius.circular(10)),
          ),
          child: Center(
            child: Icon(
              icon,
              color: color,
            ),
          ),
        ),            
        title: Text(
          title,
          style: selected? TextStyle(color: Theme.of(context).cardColor):null,
        ),
      ),
    );
  }
}
