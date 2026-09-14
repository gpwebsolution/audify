/// Formatação de durações para exibição (mm:ss / h:mm:ss).
String formatDuration(Duration d) {
  final hours = d.inHours;
  final minutes = (d.inMinutes % 60).toString().padLeft(2, '0');
  final seconds = (d.inSeconds % 60).toString().padLeft(2, '0');
  if (hours > 0) {
    return '$hours:$minutes:$seconds';
  }
  return '$minutes:$seconds';
}