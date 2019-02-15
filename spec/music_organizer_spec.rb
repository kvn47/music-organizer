RSpec.describe MusicOrganizer do
  it "has a version number" do
    expect(MusicOrganizer::VERSION).not_to be nil
  end

  describe "#organize_albums" do
    subject(:result) { described_class.organize_albums(path) }

    let(:path) { "/Volumes/S32/MUSIC/Antonio Vivaldi - Concertos" }

    it "organizes music files" do
      expect(result).to eq(:done)
    end
  end
end
