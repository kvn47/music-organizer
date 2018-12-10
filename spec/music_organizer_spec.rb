RSpec.describe MusicOrganizer do
  it "has a version number" do
    expect(MusicOrganizer::VERSION).not_to be nil
  end

  describe "#structure_albums" do
    subject(:result) { described_class.structure_albums(path) }

    let(:path) { "" }

    it "organizes music files" do
      expect(result).to be_truthy
    end
  end
end
