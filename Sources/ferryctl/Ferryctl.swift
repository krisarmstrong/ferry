import ArgumentParser

@main
struct Ferryctl: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "ferryctl",
    abstract: "Browse and copy files on an Android phone over MTP.",
    subcommands: [Devices.self, Storages.self, List.self, Get.self, Put.self]
      + [MakeFolder.self, Move.self, Rename.self, Remove.self])
}
