#
# Wraps the native PGPaymentSDK. Its XCFramework is built from the sibling
# pg_ios_sdk repo by `scripts/sync_native.sh` into ios/Frameworks/.
#
Pod::Spec.new do |s|
  s.name             = 'pg_flutter_sdk'
  s.version          = '0.1.0'
  s.summary          = 'Flutter plugin for the PG Payment SDK.'
  s.description      = <<-DESC
Flutter bridge to the native PGPaymentSDK (UPI, card and net-banking checkout).
                       DESC
  s.homepage         = 'https://github.com/pgsdk/pg_flutter_sdk'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'PG SDK' => 'sdk@example.com' }
  s.source           = { :path => '.' }
  s.source_files = 'Classes/**/*'
  s.dependency 'Flutter'
  s.platform = :ios, '15.0'

  s.vendored_frameworks = 'Frameworks/PGPaymentSDK.xcframework'
  unless File.directory?(File.join(__dir__, 'Frameworks', 'PGPaymentSDK.xcframework'))
    raise 'pg_flutter_sdk: ios/Frameworks/PGPaymentSDK.xcframework is missing. ' \
          'Run `scripts/sync_native.sh ios` in the pg_flutter_sdk repo first.'
  end

  # Flutter.framework does not contain a i386 slice.
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES', 'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386' }
  s.swift_version = '5.0'

  s.resource_bundles = {'pg_flutter_sdk_privacy' => ['Resources/PrivacyInfo.xcprivacy']}
end
