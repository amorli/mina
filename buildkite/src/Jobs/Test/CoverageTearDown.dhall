let S = ../../Lib/SelectFiles.dhall

let JobSpec = ../../Pipeline/JobSpec.dhall
let Pipeline = ../../Pipeline/Dsl.dhall
let CoverageTearDown = ../../Command/CoverageTearDown.dhall

let dependsOn =  [
    { name = "RosettaUnitTest", key = "rosetta-unit-test-dev" },
    { name = "ArchiveNodeUnitTest", key = "archive-unit-tests" },
    { name = "DaemonUnitTest", key = "unit-test-dev" },
    { name = "DelegationBackendUnitTest", key = "delegation-backend-unit-tests" },
    { name = "FuzzyZkappTest", key = "fuzzy-zkapp-unit-test-dev" },
    { name = "SingleNodeTest", key = "single-node-tests-dev" },
    { name = "ZkappTestToolUnitTest", key = "zkapp-tool-unit-test-dev" },
    { name = "TestnetIntegrationTests", key = "integration-test-peers-reliability"},
    { name = "TestnetIntegrationTests", key = "integration-test-chain-reliability"},
    { name = "TestnetIntegrationTests", key = "integration-test-payment"},
    { name = "TestnetIntegrationTests", key = "integration-test-delegation"},
    { name = "TestnetIntegrationTests", key = "integration-test-gossip-consis" },
    { name = "TestnetIntegrationTests", key = "integration-test-medium-bootstrap" },
    { name = "TestnetIntegrationTests", key = "integration-test-zkapps"},
    { name = "TestnetIntegrationTests", key = "integration-test-zkapps-timing" },
    { name = "TestnetIntegrationTests", key = "integration-test-zkapps-nonce" },
    { name = "TestnetIntegrationTests", key = "integration-test-verification-key" }
]

in Pipeline.build Pipeline.Config::{
  spec =
    JobSpec::{
    dirtyWhen = [
        S.strictlyStart (S.contains "src"),
        S.strictlyStart (S.contains "dockerfiles"),
        S.strictlyStart (S.contains "buildkite")
    ],
    path = "Test",
    name = "CoverageTearDown"
  },
  steps = [
    CoverageTearDown.execute dependsOn
  ]
}
