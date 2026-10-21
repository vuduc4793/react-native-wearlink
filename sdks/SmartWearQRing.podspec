# SmartWearKit qua CocoaPods (cho thư viện React Native). Cùng mã nguồn với Package.swift.
Pod::Spec.new do |s|
  s.name         = "SmartWearQRing"
  s.version = "0.1.4"
  s.summary      = "SmartWear SDK: qring"
  s.homepage     = "https://example.invalid/smart-wear-sdk"
  s.license      = { :type => "UNLICENSED" }
  s.author       = "SmartWear"
  s.source       = { :path => "." }
  s.platforms    = { :ios => "15.1" }
  s.swift_version = "5.10"
  s.module_name  = "SmartWearQRing"
  s.source_files = "qring/ios/Sources/SmartWearQRing/**/*.swift"
  s.frameworks   = "CoreBluetooth"
  s.dependency "SmartWearCore"
end
