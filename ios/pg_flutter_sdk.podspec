#
# Wraps the native PGPaymentSDK.
#
# The XCFramework is downloaded from a pinned GitHub release on `pod install`
# and checked against PG_SDK_SHA256. For local development against the
# sibling pg_ios_sdk repo, `scripts/sync_native.sh ios` puts a build in
# ios/Frameworks/ instead, and that copy is used as-is.
#
require 'digest'
require 'fileutils'
require 'tmpdir'

PG_SDK_VERSION = '1.0.0'
PG_SDK_URL = "https://github.com/AteequeJ/pg_sdk_ios/releases/download/v#{PG_SDK_VERSION}/PGPaymentSDK.xcframework.zip"
# `shasum -a 256 PGPaymentSDK.xcframework.zip` of the release asset.
PG_SDK_SHA256 = '68e0dbdefcf87bbbfa845088ce54df362b511b39bd983e3adbd217d5099dd9ee'

frameworks_dir = File.join(__dir__, 'Frameworks')
framework_path = File.join(frameworks_dir, 'PGPaymentSDK.xcframework')

unless File.directory?(framework_path)
  Dir.mktmpdir do |tmp|
    zip = File.join(tmp, 'PGPaymentSDK.xcframework.zip')
    system('curl', '-fsSL', '--retry', '3', '-o', zip, PG_SDK_URL) or
      raise "pg_flutter_sdk: failed to download #{PG_SDK_URL}"
    actual = Digest::SHA256.file(zip).hexdigest
    unless actual == PG_SDK_SHA256
      raise "pg_flutter_sdk: checksum mismatch for #{PG_SDK_URL} " \
            "(expected #{PG_SDK_SHA256}, got #{actual})"
    end
    system('ditto', '-x', '-k', zip, tmp) or
      raise 'pg_flutter_sdk: failed to unzip PGPaymentSDK.xcframework.zip'
    FileUtils.mkdir_p(frameworks_dir)
    FileUtils.mv(File.join(tmp, 'PGPaymentSDK.xcframework'), framework_path)
  end
end

Pod::Spec.new do |s|
  s.name             = 'pg_flutter_sdk'
  s.version          = '0.1.0'
  s.summary          = 'Flutter plugin for the PG Payment SDK.'
  s.description      = <<-DESC
Flutter bridge to the native PGPaymentSDK (UPI, card and net-banking checkout).
                       DESC
  s.homepage         = 'https://github.com/AteequeJ/pg_sdk_flutter'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'Ateeque Jamadar' => 'tripleapaywize@gmail.com' }
  s.source           = { :path => '.' }
  s.source_files = 'Classes/**/*'
  s.dependency 'Flutter'
  s.platform = :ios, '15.0'

  s.vendored_frameworks = 'Frameworks/PGPaymentSDK.xcframework'

  # Flutter.framework does not contain a i386 slice.
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES', 'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386' }
  s.swift_version = '5.0'

  s.resource_bundles = {'pg_flutter_sdk_privacy' => ['Resources/PrivacyInfo.xcprivacy']}
end
