import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class TerminalLogEntry {
  final String text;
  final bool isError;
  final DateTime timestamp;

  TerminalLogEntry({
    required this.text,
    this.isError = false,
    DateTime? timestamp,
  }) : timestamp = timestamp ?? DateTime.now();
}

/// 现代极简风格的实时终端控制台日志组件 (用于 Windows 开放扩展与长耗时任务)
class TerminalLogViewer extends StatefulWidget {
  final List<TerminalLogEntry> logs;
  final bool isRunning;
  final VoidCallback? onStop;
  final VoidCallback? onClear;
  final bool initiallyExpanded;

  const TerminalLogViewer({
    super.key,
    required this.logs,
    this.isRunning = false,
    this.onStop,
    this.onClear,
    this.initiallyExpanded = true,
  });

  @override
  State<TerminalLogViewer> createState() => _TerminalLogViewerState();
}

class _TerminalLogViewerState extends State<TerminalLogViewer> {
  final ScrollController _scrollController = ScrollController();
  bool _autoScroll = true;
  late bool _isExpanded;

  @override
  void initState() {
    super.initState();
    _isExpanded = widget.initiallyExpanded;
  }

  @override
  void didUpdateWidget(TerminalLogViewer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_autoScroll && widget.logs.length != oldWidget.logs.length) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_scrollController.hasClients) {
          _scrollController.animateTo(
            _scrollController.position.maxScrollExtent,
            duration: const Duration(milliseconds: 150),
            curve: Curves.easeOut,
          );
        }
      });
    }
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  void _copyAllLogs() {
    final allText = widget.logs.map((e) => e.text).join('\n');
    Clipboard.setData(ClipboardData(text: allText));
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('已复制完整终端日志到剪贴板'), duration: Duration(seconds: 2)),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF0F172A),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFF334155)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.2),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // 终端顶栏 (Title & Actions)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            color: const Color(0xFF1E293B),
            child: Row(
              children: [
                // 经典终端红黄绿指示点
                Row(
                  children: [
                    Container(width: 10, height: 10, decoration: const BoxDecoration(color: Color(0xFFEF4444), shape: BoxShape.circle)),
                    const SizedBox(width: 6),
                    Container(width: 10, height: 10, decoration: const BoxDecoration(color: Color(0xFFF59E0B), shape: BoxShape.circle)),
                    const SizedBox(width: 6),
                    Container(width: 10, height: 10, decoration: const BoxDecoration(color: Color(0xFF10B981), shape: BoxShape.circle)),
                  ],
                ),
                const SizedBox(width: 12),
                const Icon(Icons.terminal_rounded, size: 16, color: Color(0xFF38BDF8)),
                const SizedBox(width: 6),
                const Text(
                  '实时终端控制台',
                  style: TextStyle(
                    color: Color(0xFFF8FAFC),
                    fontWeight: FontWeight.bold,
                    fontSize: 13,
                    fontFamily: 'monospace',
                  ),
                ),
                const SizedBox(width: 8),
                if (widget.isRunning)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      color: const Color(0xFF0284C7).withValues(alpha: 0.3),
                      borderRadius: BorderRadius.circular(4),
                      border: Border.all(color: const Color(0xFF38BDF8)),
                    ),
                    child: const Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        SizedBox(
                          width: 8,
                          height: 8,
                          child: CircularProgressIndicator(strokeWidth: 1.5, color: Color(0xFF38BDF8)),
                        ),
                        SizedBox(width: 6),
                        Text(
                          'RUNNING',
                          style: TextStyle(color: Color(0xFF38BDF8), fontSize: 10, fontWeight: FontWeight.bold),
                        ),
                      ],
                    ),
                  )
                else
                  Text(
                    '(${widget.logs.length} 行)',
                    style: const TextStyle(color: Color(0xFF64748B), fontSize: 11),
                  ),
                const Spacer(),
                // 停止进程
                if (widget.isRunning && widget.onStop != null) ...[
                  InkWell(
                    onTap: widget.onStop,
                    borderRadius: BorderRadius.circular(4),
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                      decoration: BoxDecoration(
                        color: const Color(0xFFEF4444).withValues(alpha: 0.2),
                        borderRadius: BorderRadius.circular(4),
                        border: Border.all(color: const Color(0xFFEF4444)),
                      ),
                      child: const Row(
                        children: [
                          Icon(Icons.stop_circle_outlined, size: 14, color: Color(0xFFF87171)),
                          SizedBox(width: 4),
                          Text('终止进程', style: TextStyle(color: Color(0xFFF87171), fontSize: 11, fontWeight: FontWeight.bold)),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                ],
                // 自动滚屏开关
                InkWell(
                  onTap: () => setState(() => _autoScroll = !_autoScroll),
                  child: Tooltip(
                    message: _autoScroll ? '已开启自动滚屏' : '已暂停自动滚屏',
                    child: Icon(
                      _autoScroll ? Icons.arrow_downward_rounded : Icons.pause_circle_outline,
                      size: 17,
                      color: _autoScroll ? const Color(0xFF38BDF8) : const Color(0xFF64748B),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                // 复制日志
                InkWell(
                  onTap: _copyAllLogs,
                  child: const Tooltip(
                    message: '复制日志',
                    child: Icon(Icons.copy_rounded, size: 16, color: Color(0xFF94A3B8)),
                  ),
                ),
                const SizedBox(width: 10),
                // 清空日志
                if (widget.onClear != null) ...[
                  InkWell(
                    onTap: widget.onClear,
                    child: const Tooltip(
                      message: '清空控制台',
                      child: Icon(Icons.delete_sweep_outlined, size: 17, color: Color(0xFF94A3B8)),
                    ),
                  ),
                  const SizedBox(width: 10),
                ],
                // 折叠/展开
                InkWell(
                  onTap: () => setState(() => _isExpanded = !_isExpanded),
                  child: Icon(
                    _isExpanded ? Icons.keyboard_arrow_up : Icons.keyboard_arrow_down,
                    size: 20,
                    color: const Color(0xFF94A3B8),
                  ),
                ),
              ],
            ),
          ),

          // 终端黑框正文
          if (_isExpanded)
            Container(
              height: 220,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              color: const Color(0xFF0B1120),
              child: widget.logs.isEmpty
                  ? const Center(
                      child: Text(
                        '等待执行命令，标准输出与错误流将在此实时呈现...',
                        style: TextStyle(color: Color(0xFF475569), fontSize: 12, fontFamily: 'monospace'),
                      ),
                    )
                  : ListView.builder(
                      controller: _scrollController,
                      itemCount: widget.logs.length,
                      itemBuilder: (ctx, idx) {
                        final entry = widget.logs[idx];
                        Color textColor = const Color(0xFFCBD5E1);
                        if (entry.isError) {
                          textColor = const Color(0xFFF87171); // 红色错误/警告
                        } else if (entry.text.startsWith('>>>')) {
                          textColor = const Color(0xFF38BDF8); // 蓝色系统引导指令
                        } else if (entry.text.contains('[download]') || entry.text.contains('%')) {
                          textColor = const Color(0xFF34D399); // 绿色进度信息
                        } else if (entry.text.startsWith('【')) {
                          textColor = const Color(0xFFA78BFA); // 紫色功能头
                        }

                        return Padding(
                          padding: const EdgeInsets.symmetric(vertical: 1.5),
                          child: SelectableText(
                            entry.text,
                            style: TextStyle(
                              color: textColor,
                              fontSize: 12,
                              fontFamily: 'Consolas',
                              height: 1.35,
                            ),
                          ),
                        );
                      },
                    ),
            ),
        ],
      ),
    );
  }
}
