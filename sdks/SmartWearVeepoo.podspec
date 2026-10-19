# SmartWearKit qua CocoaPods (cho thư viện React Native). Cùng mã nguồn với Package.swift.
Pod::Spec.new do |s|
  s.name         = "SmartWearVeepoo"
  s.version      = "0.1.0"
  s.summary      = "SmartWear SDK: veepoo"
  s.homepage     = "https://example.invalid/smart-wear-sdk"
  s.license      = { :type => "UNLICENSED" }
  s.author       = "SmartWear"
  s.source       = { :path => "." }
  s.platforms    = { :ios => "17.0" }
  s.swift_version = "5.10"
  s.module_name  = "SmartWearVeepoo"
  s.source_files = "veepoo/ios/Sources/SmartWearVeepoo/**/*.swift"
  s.frameworks   = "CoreBluetooth"
  s.dependency "SmartWearCore"
end
