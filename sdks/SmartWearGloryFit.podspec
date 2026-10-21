# SmartWearKit qua CocoaPods (cho thư viện React Native). Cùng mã nguồn với Package.swift.
Pod::Spec.new do |s|
  s.name         = "SmartWearGloryFit"
  s.version = "0.1.2"
  s.summary      = "SmartWear SDK: gloryfit"
  s.homepage     = "https://example.invalid/smart-wear-sdk"
  s.license      = { :type => "UNLICENSED" }
  s.author       = "SmartWear"
  s.source       = { :path => "." }
  s.platforms    = { :ios => "15.1" }
  s.swift_version = "5.10"
  s.module_name  = "SmartWearGloryFit"
  s.source_files = "gloryfit/ios/Sources/SmartWearGloryFit/**/*.swift"
  s.frameworks   = "CoreBluetooth"
  s.dependency "SmartWearCore"
end
