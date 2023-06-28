let Prelude = ../../External/Prelude.dhall

let Cmd = ../../Lib/Cmds.dhall
let S = ../../Lib/SelectFiles.dhall
let D = S.PathPattern

let Pipeline = ../../Pipeline/Dsl.dhall
let JobSpec = ../../Pipeline/JobSpec.dhall

let Command = ../../Command/Base.dhall
let RunInToolchain = ../../Command/RunInToolchain.dhall
let Docker = ../../Command/Docker/Type.dhall
let Size = ../../Command/Size.dhall


let dependsOn = [
    { name = "MinaArtifactBullseye", key = "build-deb-pkg" }
]

in 

let buildTestCmd : Text -> Size -> List Command.TaggedKey.Type -> Command.Type = \(release_branch : Text) -> \(cmd_target : Size) -> \(dependsOn : List Command.TaggedKey.Type) ->
  Command.build
    Command.Config::{
        commands =          
           ---Cmd.runInDocker
             ---Cmd.Docker::{
          ---     image = (../../Constants/ContainerImages.dhall).ubuntu2004
          ---   }
          ---   "buildkite/scripts/download-mina-deb.sh berkeley"
         ---  ]
         ---  #
          RunInToolchain.runInToolchain ([] : List Text) "buildkite/scripts/version-linter.sh ${release_branch}",
      label = "Versioned type linter",
      key = "version-linter",
      target = cmd_target,
      docker = None Docker.Type,
      artifact_paths = [ S.contains "core_dumps/*" ],
      depends_on = dependsOn
    }

in

Pipeline.build
  Pipeline.Config::{
    spec =
      let lintDirtyWhen = [
        S.strictlyStart (S.contains "src/lib"),
        S.exactly "buildkite/src/Jobs/Test/VersionLint" "dhall",
        S.exactly "buildkite/scripts/version_linter" "sh"
      ]

      in

      JobSpec::{
        dirtyWhen = lintDirtyWhen,
        path = "Test",
        name = "VersionLint"
      },
    steps = [
      buildTestCmd "develop" Size.Small dependsOn
    ]
  }
