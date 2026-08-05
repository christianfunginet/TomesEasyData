
import 'package:flutter/material.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';
//import 'package:material_charts/material_charts.dart';

class EpisodicPage extends StatefulWidget {
  final List<String> episodios;
  final List<String> machineData;
  final Function onClose;
  const EpisodicPage({super.key, required this.episodios, required this.machineData, required this.onClose});

  @override
  State<EpisodicPage> createState() => _EpisodicPageState();
}

class _EpisodicPageState extends State<EpisodicPage> {
  // Define the initial viewport
  @override
  void initState() {
    super.initState();
  }

  final ItemScrollController _scrollController = ItemScrollController();
  final TextEditingController _textEditingController = TextEditingController();
  String xerchText = "";
  List<int> indexFound = [];
  int ptr = 0;
  @override
  Widget build(BuildContext context) {
    // This method is rerun every time setState is called, for instance as done
    // by the _incrementCounter method above.
    //
    // The Flutter framework has been optimized to make rerunning build methods
    // fast, so that you can just rebuild anything that needs updating rather
    // than having to individually change instances of widgets.
    return SafeArea(
      child: SizedBox(
        height: MediaQuery.of(context).size.height,
        width: MediaQuery.of(context).size.width,
        child: Row(
          children: [
            Card(
              child: SizedBox(
                width: MediaQuery.of(context).size.width * 0.66,
                            height: MediaQuery.of(context).size.width -150,
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Padding(
                      padding: const EdgeInsets.all(8.0),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        mainAxisSize: MainAxisSize.max,

                        children: [
                          SizedBox(
                            width: MediaQuery.of(context).size.width * 0.66 * 0.66,
                            child: TextFormField(
                              controller: _textEditingController,
                              onChanged: (value) {
                                indexFound.clear();
                                int index = 0;
                                for (var linea in widget.episodios) {
                                  if (linea.toLowerCase().contains(value.toLowerCase())) {
                                    indexFound.add(index);
                                  }
                                  index++;
                                }
                                setState(() {
                                  ptr = 0;
                                  indexFound;
                                });
                              },
                              decoration: InputDecoration(
                                border: OutlineInputBorder(
                                  borderSide: BorderSide(color: Theme.of(context).primaryColor),
                                  borderRadius: BorderRadius.circular(9),
                                ),
                              ),
                            ),
                          ),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.end,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              if (indexFound.isNotEmpty) ...[Text("Line: ${indexFound[ptr] + 1}")],
                              SizedBox(width: 10),
                              IconButton(
                                onPressed: () {
                                  ptr--;
                                  if (ptr < 0) {
                                    ptr = indexFound.length - 1;
                                  }
                                  _scrollController.jumpTo(alignment: 0.5, index: indexFound[ptr]);
                                  setState(() {
                                    ptr;
                                  });
                                },
                                icon: Icon(Icons.keyboard_arrow_up),
                              ),
                              Text("${ptr + 1} / ${indexFound.length}"),
                              IconButton(
                                onPressed: () {
                                  ptr++;
                                  if (ptr >= indexFound.length + 1) {
                                    ptr = 0;
                                  }
                                  _scrollController.jumpTo(alignment: 0.5, index: indexFound[ptr]);
                                  setState(() {
                                    ptr;
                                  });
                                },
                                icon: Icon(Icons.keyboard_arrow_down),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.all(8.0),
                      child: SizedBox(
                        height: MediaQuery.of(context).size.height - 260,
                        width: MediaQuery.of(context).size.width,
                        child: ScrollablePositionedList.builder(
                          itemScrollController: _scrollController,
                          shrinkWrap: true,
                          itemCount: widget.episodios.length,
                          itemBuilder: (context, index) {
                            return Container(
                              decoration: BoxDecoration(
                                color: indexFound.isNotEmpty && indexFound[ptr] == index
                                    ? Colors.greenAccent.withAlpha(120)
                                    : indexFound.contains(index)
                                    ? Colors.greenAccent.withAlpha(20)
                                    : null,
                                border: indexFound.contains(index) ? BoxBorder.all(color: Colors.greenAccent.withAlpha(60)) : null,
                              ),
                              child: Text("${index + 1} - ${widget.episodios[index]}"),
                            );
                          },
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            Card(
              child: SizedBox(
                width: MediaQuery.of(context).size.width * 0.3,
                height: MediaQuery.of(context).size.height-100,
                child: Padding(
                  padding: const EdgeInsets.all(8.0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SizedBox(height: 10),
                      Text("Equipment data"),
                      SizedBox(height: 30),
                      SizedBox(
                        height: 300,
                        child: ListView.builder(
                          itemCount: widget.machineData.length,
                          shrinkWrap: true,
                          itemBuilder: (context, index) {
                            return Card(
                              child: Padding(padding: const EdgeInsets.all(8.0), child: Text(widget.machineData[index])),
                            );
                          },
                        ),
                      ),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          OutlinedButton(
                            onPressed: () async {
                              widget.onClose.call();
                            },
                            child: const Text('GRAPHIC'),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),
            
          ],
        ),
      ),
    );
    // This trailing comma makes auto-formatting nicer for build methods.
  }
}
