# bt-peer-policy-generator-ps1
BT peer policy generator
## Intro
It is possible to improve network throughput of certain peer-to-peer software by providing peer policy file. Peer policy is a xml file containing priority ip network ranges. 
Script PeerPolicy.ps1 processes common IP/CIDR format input to bt peer policy xml format.
PeerPolicy.Web.ps1 is experimental self-hosted web ui for configuring and executing of the PeerPolicy.ps1

## Usage samples:
Repository contains few batch files with sample commands:
ProcessSampleData.cmd - uses PeerPolicy.ps1 to geneerate result xml file
RunWeb.cmd - starts web host and opens configuration in browser
RunTests.cmd - run unit and integration tests. Please run InstallPester.cmd first. 
More info to be done.