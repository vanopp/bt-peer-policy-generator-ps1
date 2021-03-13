# bt-peer-policy-generator-ps1
BT peer policy generator
## Intro
It is possible to improve the network throughput of certain peer-to-peer software by providing a peer policy file. Peer policy is an XML file containing priority IP network ranges.\
PeerPolicy.ps1 script processes common IP/CIDR format input to bt peer policy XML format.\
PeerPolicy.Web.ps1 is an experimental self-hosted web UI for configuring and executing the PeerPolicy.ps1

## Usage samples:
Repository contains few batch files with sample commands:\
ProcessSampleData.cmd - uses PeerPolicy.ps1 to generate result xml file\
RunWeb.cmd - starts web host and opens configuration in browser\
RunTests.cmd - run unit and integration tests. Please run InstallPester.cmd first.

More info to be done.
