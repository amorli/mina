let Prelude = ../External/Prelude.dhall

let Command = ./Base.dhall
let Docker = ./Docker/Type.dhall
let Size = ./Size.dhall

let Cmd = ../Lib/Cmds.dhall in

{ step = \(dependsOn : List Command.TaggedKey.Type) ->
    Command.build
      Command.Config::{
        commands = [
          Cmd.runInDocker
            Cmd.Docker::{
              image = (../Constants/ContainerImages.dhall).minaArchive,
              entrypoint = " --entrypoint=/bin/sh"
            }
            "./buildkite/scripts/replayer-test.sh"
        ],
        label = "Replayer test",
        key = "replayer-test",
        target = Size.Large,
        depends_on = dependsOn
      }
}
