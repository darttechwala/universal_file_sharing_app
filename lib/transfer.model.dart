class TransferItem {
  String device;
  String fileName;
  int total;
  int transferred;
  String status;

  TransferItem({
    required this.device,
    required this.fileName,
    required this.total,
    this.transferred = 0,
    this.status = "waiting",
  });

  double get progress => total == 0 ? 0 : transferred / total;
}
