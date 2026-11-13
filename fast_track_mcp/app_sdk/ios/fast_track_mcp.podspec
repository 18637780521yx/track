Pod::Spec.new do |s|
  s.name             = 'fast_track_mcp'
  s.version          = '0.10.0'
  s.summary          = 'Fast Track MCP native ANR / App Hang detection'
  s.description      = 'Android/iOS native hang watchdog for Fast Track MCP.'
  s.homepage         = 'https://github.com/local/fast_track_mcp'
  s.license          = { :type => 'MIT' }
  s.author           = { 'FastTrack' => 'dev@example.com' }
  s.source           = { :path => '.' }
  s.source_files     = 'Classes/**/*'
  s.public_header_files = 'Classes/**/*.h'
  s.dependency 'Flutter'
  s.platform = :ios, '12.0'
  s.weak_frameworks = 'MetricKit'
  s.requires_arc = true
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES' }
  s.swift_version = '5.0'
end
