require "json"

package = JSON.parse(File.read(File.join(__dir__, "package.json")))

# Thư viện RN `react-native-smartwear` (iOS). SDK Swift (SmartWearCore/QRing/GloryFit/Standard/Veepoo) là các pod riêng
# trong `sdks/`, khai báo trong Podfile của app (xem README).
Pod::Spec.new do |s|
  s.name         = "react-native-smartwear"
  s.version      = package["version"]
  s.summary      = package["description"]
  s.homepage     = "https://example.invalid/smart-wear-sdk"
  s.license      = { :type => "UNLICENSED" }
  s.author       = "SmartWear"
  s.platforms    = { :ios => "17.0" }
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
