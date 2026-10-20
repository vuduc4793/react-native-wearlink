require "json"

package = JSON.parse(File.read(File.join(__dir__, "package.json")))

# Thư viện RN `react-native-wearlink` (iOS). SDK Swift (SmartWearCore/QRing/GloryFit/Standard/Veepoo) là các pod riêng
# trong `sdks/`, khai báo trong Podfile của app (xem README).
Pod::Spec.new do |s|
  s.name         = "react-native-wearlink"
  s.version      = package["version"]
  s.summary      = package["description"]
  s.homepage     = "https://github.com/vuduc4793/react-native-wearlink"
  s.license      = { :type => "UNLICENSED" }
  s.author       = "SmartWear"
  s.platforms    = { :ios => "15.1" }
  s.source       = { :path => "." }
  s.source_files = "ios/**/*.{h,m,mm,swift}"
  s.swift_version = "5.10"

  s.dependency "SmartWearCore"
  s.dependency "SmartWearQRing"
  s.dependency "SmartWearGloryFit"
  s.dependency "SmartWearStandard"
  s.dependency "SmartWearVeepoo"

  install_modules_dependencies(s)
end
