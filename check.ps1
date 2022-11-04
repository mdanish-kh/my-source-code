#   Copyright 2020 Jacob Kiesel
#
#   Licensed under the Apache License, Version 2.0 (the "License");
#   you may not use this file except in compliance with the License.
#   You may obtain a copy of the License at
#
#       http://www.apache.org/licenses/LICENSE-2.0
#
#   Unless required by applicable law or agreed to in writing, software
#   distributed under the License is distributed on an "AS IS" BASIS,
#   WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
#   See the License for the specific language governing permissions and
#   limitations under the License.

# Load up code for getting product codes from an MSI file.
$msiTools = Add-Type -PassThru -Name 'MsiTools' -Using 'System.Text' -MemberDefinition $(Get-Content "MsiTools.cs")
Set-PSRepository -Name "PSGallery" -InstallationPolicy Trusted
Install-Module -Name powershell-yaml -AcceptLicense
Import-Module powershell-yaml
gh auth setup-git
git config --global user.email "kieseljake+rust-winget-bot@live.com"
git config --global user.name "Rust-Winget-Bot"
gh repo clone "Rust-Winget-Bot/winget-pkgs"
Set-Location winget-pkgs
git pull upstream master
git push
$yamlHeader = @'
# Auto-generated by Rust-Winget-Bot (https://github.com/Rust-Winget-Bot)
# yaml-language-server: $schema=https://aka.ms/winget-manifest.installer.1.2.0.schema.json


'@
$lastFewVersions = git ls-remote --sort=-v:refname --tags https://github.com/rust-lang/rust.git
  | Select-String -Pattern "refs/tags/(\d+?\.\d+?\.\d+?$)"
  | ForEach-Object { $_.Matches[0].Groups[1].Value }
  | Select-Object -First 3;
$myPrs = gh pr list --author "Rust-Winget-Bot" --repo "microsoft/winget-pkgs" --state=all
  | Foreach-Object {((($_ -split '\t')[2]) -split ':')[1]};
foreach ($toolchain in @("MSVC", "GNU")) {
    $toolchainLower = $toolchain.ToLower();
    $publishedVersions = Get-ChildItem .\manifests\r\Rustlang\Rust\$toolchain
      | Foreach-Object {$_.Name}
      | Where-Object {!$_.Contains('.validation')}
      | Select-Object -Last 5
    foreach ($version in $lastFewVersions) {
        if ($publishedVersions.Contains($version)) {
            continue;
        } else {
            if ($myPrs -and $myPrs.Contains("rust-$version-$toolchainLower")) {
                continue;
            }
            Write-Output "Creating branch for $version $toolchain"
            git checkout master;
            git checkout -b rust-$version-$toolchainLower;
            New-Item "manifests/r/Rustlang/Rust/$toolchain/$version/" -ItemType Directory -ea 0
            $yamlPath = "manifests/r/Rustlang/Rust/$toolchain/$version/Rustlang.Rust.$toolchain.installer.yaml";
            $yamlObject = [ordered]@{
                PackageIdentifier = "Rustlang.Rust.$toolchain";
                PackageVersion = $version;
                MinimumOSVersion = "10.0.0.0";
                InstallerType = "wix";
                UpgradeBehavior = "uninstallPrevious";
                Installers = @(); # To be filled later
                ManifestType = "installer";
                ManifestVersion = "1.2.0";
            };
             if ($toolchain -eq "MSVC") {
                $installers = @(
                    "https://static.rust-lang.org/dist/rust-$version-aarch64-pc-windows-msvc.msi",
                    "https://static.rust-lang.org/dist/rust-$version-i686-pc-windows-msvc.msi",
                    "https://static.rust-lang.org/dist/rust-$version-x86_64-pc-windows-msvc.msi"
                );
            } else {
                $installers = @(
                    "https://static.rust-lang.org/dist/rust-$version-i686-pc-windows-gnu.msi",
                    "https://static.rust-lang.org/dist/rust-$version-x86_64-pc-windows-gnu.msi"
                );
            }
            foreach ($installer in $installers) {
                $path = $installer.Substring($installer.LastIndexOf('/') + 1);
                Write-Output "Now downloading $path from $installer"
                Invoke-WebRequest -Uri $installer -Outfile $path
                if(!$?) {
                    Write-Output "Failed to download file, skipping"
                    continue;
                }
                $sha256 = (Get-FileHash $path -Algorithm SHA256).Hash;
                Remove-Item $path;
                Invoke-WebRequest -Uri $installer -Outfile $path
                if(!$?) {
                    Write-Output "Failed to download file, skipping"
                    continue;
                }
                $sha256_2 = (Get-FileHash $path -Algorithm SHA256).Hash;
                if (-not($sha256 -eq $sha256_2)) {
                    throw "Sha256 returned two different results, shutting down to lack of confidence in sha value"
                }
                $absolutePath = Resolve-Path $path;
                $productCode = $msiTools::GetProductCode($absolutePath)
                $productName = $msiTools::GetProductName($absolutePath);
                $productVersion = $msiTools::GetProductVersion($absolutePath);
                Remove-Item $path;
                $arch = if ($installer.Contains("i686")) {
                    "x86"
                } elseif ($installer.Contains("x86_64")) {
                    "x64"
                } elseif ($installer.Contains("aarch64")) {
                    "arm64"
                }
                
                $appsAndFeaturesEntry = [ordered]@{
                    DisplayName = $productName;
                    ProductCode = $productCode;
                    DisplayVersion = $productVersion;
                };
                $installerEntry = [ordered]@{
                    Architecture = $arch;
                    InstallerUrl = $installer;
                    InstallerSha256 = $sha256;
                    ProductCode = $productCode;
                    AppsAndFeaturesEntries = @($appsAndFeaturesEntry);
                };
                $yamlObject.Installers += $installerEntry
            }
            $newYamlData = -join($yamlHeader, (ConvertTo-YAML $yamlObject));
            Set-Content -Path $yamlPath -Value $newYamlData;
            $yamlPath = "manifests/r/Rustlang/Rust/$toolchain/$version/Rustlang.Rust.$toolchain.locale.en-US.yaml";
            $yamlObject = [ordered]@{
                PackageIdentifier = "Rustlang.Rust.$toolchain";
                PackageVersion = $version;
                PackageLocale = "en-US";
                Publisher = "The Rust Project Developers";
                PublisherUrl = "https://github.com/rust-lang/rust";
                PublisherSupportUrl = "https://github.com/rust-lang/rust/issues";
                Author = "The Rust Project Developers";
                PackageName = "Rust ($toolchain)";
                PackageUrl = "https://www.rust-lang.org/";
                License = "Apache 2.0 and MIT";
                LicenseUrl = "https://raw.githubusercontent.com/rust-lang/rust/master/COPYRIGHT";
                CopyrightUrl = "https://raw.githubusercontent.com/rust-lang/rust/master/COPYRIGHT";
                ShortDescription = "this is the rust-lang built with $toolchainLower toolchain";
                Moniker = "rust-$toolchainLower";
                Tags = @($toolchainLower, "rust", "windows");
                ManifestType = "defaultLocale";
                ManifestVersion = "1.2.0";
            };
            $newYamlData = -join($yamlHeader, (ConvertTo-YAML $yamlObject));
            Set-Content -Path $yamlPath -Value $newYamlData;
            $yamlPath = "manifests/r/Rustlang/Rust/$toolchain/$version/Rustlang.Rust.$toolchain.yaml";
            $yamlObject = [ordered]@{
                PackageIdentifier = "Rustlang.Rust.$toolchain";
                PackageVersion = $version;
                DefaultLocale = "en-US";
                ManifestType = "version";
                ManifestVersion = "1.2.0";
            };
            $newYamlData = -join($yamlHeader, (ConvertTo-YAML $yamlObject));
            Set-Content -Path $yamlPath -Value $newYamlData;
            git add --all .
            git commit -m"add Rustlang.Rust.$toolchain version $version"
            git push -u origin rust-$version-$toolchainLower;

            $title = "add Rustlang.Rust.$toolchain version $version";
            $body = "This PR is auto-generated. If there's something wrong, please file an issue at https://github.com/Rust-Winget-Bot/my-source-code/issues";
            gh pr create --title $title --body $body
        }
    }
}
$closedPRs = gh pr list --author "Rust-Winget-Bot" --repo "microsoft/winget-pkgs" --state=closed --limit 10
  | Foreach-Object {((($_ -split '\t')[2]) -split ':')[1]};

foreach ($pr in $closedPRs) {
    git push origin -d $pr
}

