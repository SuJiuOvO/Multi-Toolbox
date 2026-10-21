/// 社区模块市场远程镜像节点定义
class RegistryMirrorNode {
  final String id;
  final String name;
  final String indexUrl;
  final String pingUrl;
  final String packageBaseUrl;
  final String appVersionUrl;
  final String icon;

  const RegistryMirrorNode({
    required this.id,
    required this.name,
    required this.indexUrl,
    required this.pingUrl,
    required this.packageBaseUrl,
    required this.appVersionUrl,
    this.icon = '🌐',
  });

  /// 官方默认预设多镜像节点池 (覆盖国内极速、全球 CDN 与国际直连)
  static const List<RegistryMirrorNode> defaultNodes = [
    RegistryMirrorNode(
      id: 'gitee',
      name: '国内高速镜像 (Gitee 极速)',
      icon: '🚀',
      indexUrl: 'https://gitee.com/sujiuovo/toolbox-community-registry/raw/master/registry/index.json',
      pingUrl: 'https://gitee.com/sujiuovo/toolbox-community-registry/raw/master/registry/ping.json',
      packageBaseUrl: 'https://gitee.com/sujiuovo/toolbox-community-registry/raw/master',
      appVersionUrl: 'https://gitee.com/sujiuovo/toolbox-community-registry/raw/master/registry/app_version.json',
    ),
    RegistryMirrorNode(
      id: 'github_cdn',
      name: '全球加速 CDN (jsDelivr 免梯)',
      icon: '⚡',
      indexUrl: 'https://cdn.jsdelivr.net/gh/SuJiuOvO/Toolbox-Community-Registry@main/registry/index.json',
      pingUrl: 'https://cdn.jsdelivr.net/gh/SuJiuOvO/Toolbox-Community-Registry@main/registry/ping.json',
      packageBaseUrl: 'https://cdn.jsdelivr.net/gh/SuJiuOvO/Toolbox-Community-Registry@main',
      appVersionUrl: 'https://cdn.jsdelivr.net/gh/SuJiuOvO/Toolbox-Community-Registry@main/registry/app_version.json',
    ),
    RegistryMirrorNode(
      id: 'github_raw',
      name: 'GitHub 官方源 (国际直连)',
      icon: '🐙',
      indexUrl: 'https://raw.githubusercontent.com/SuJiuOvO/Toolbox-Community-Registry/main/registry/index.json',
      pingUrl: 'https://raw.githubusercontent.com/SuJiuOvO/Toolbox-Community-Registry/main/registry/ping.json',
      packageBaseUrl: 'https://raw.githubusercontent.com/SuJiuOvO/Toolbox-Community-Registry/main',
      appVersionUrl: 'https://raw.githubusercontent.com/SuJiuOvO/Toolbox-Community-Registry/main/registry/app_version.json',
    ),
  ];
}
