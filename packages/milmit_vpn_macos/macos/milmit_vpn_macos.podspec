Pod::Spec.new do |s|
  s.name             = 'milmit_vpn_macos'
  s.version          = '0.1.0'
  s.summary          = 'MilMit VPN macOS NetworkExtension bridge.'
  s.description      = <<-DESC
Native Flutter bridge for configuring and controlling MilMit VPN PacketTunnel.
                       DESC
  s.homepage         = 'https://milmit.net'
  s.license          = { :type => 'MIT' }
  s.author           = { 'MilMit' => 'support@milmit.net' }
  s.source           = { :path => '.' }
  s.source_files     = 'Classes/**/*'
  s.dependency 'FlutterMacOS'
  s.platform = :osx, '12.0'
  s.swift_version = '5.0'
  s.frameworks = 'NetworkExtension'
end
