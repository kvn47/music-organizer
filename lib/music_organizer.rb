require "music_organizer/version"

require 'taglib'
require 'rubycue'
require 'fileutils'
require 'shellwords'

module MusicOrganizer
  Album = Struct.new(:artist, :album_artist, :title, :year, :genre, :tracks,
                     :path, :cue_file_path, :music_file_path, :cover_path, keyword_init: true) do
    def dir_name
      year ? "#{title} (#{year})" : title
    end
  end

  Track = Struct.new(:artist, :album, :year, :number, :title, :genre, :path, keyword_init: true)
  ROMAN_NUMBERS = %w[I II III IV V VI VII VIII IX X].freeze

  module_function

  def organize_albums(path)
    return :path_not_found unless Dir.exist?(path)

    albums = collect_albums(path)
    return :albums_not_found if albums.empty?

    dst_path = File.expand_path('..', path)

    albums.each do |album|
      if album.genre == 'Classical'
        organize_classical_album(album, dst_path)
      else
        organize_regular_album(album, dst_path)
      end
    end

    :done
  end

  def collect_albums(path)
    merged_albums = collect_merged_albums(path)
    splitted_albums = collect_splitted_albums(path)
    merged_albums + splitted_albums
  end

  def collect_merged_albums(path)
    albums = []

    Dir.glob('**/*.cue', base: path).each do |cue_file_name|
      cue_file_path = File.join(path, cue_file_name)
      cue_sheet = RubyCue::Cuesheet.new(File.read(cue_file_path))
      cue_sheet.parse!
      next if cue_sheet.file.nil?

      album_path = File.dirname(cue_file_path)
      music_file_path = File.join(album_path, cue_sheet.file)
      next unless File.exist?(music_file_path)

      tracks = cue_sheet.songs.map do |cue_track|
        Track.new(title: cue_track[:title],
                  artist: cue_track[:performer],
                  number: cue_track[:track],
                  album: cue_sheet.title,
                  genre: cue_sheet.genre,
                  year: cue_sheet.date)
      end

      cover_path = find_cover(album_path)

      albums << Album.new(title: cue_sheet.title,
                          artist: cue_sheet.performer,
                          album_artist: cue_sheet.performer,
                          genre: cue_sheet.genre,
                          year: cue_sheet.date,
                          path: album_path,
                          cue_file_path: cue_file_path,
                          music_file_path: music_file_path,
                          cover_path: cover_path,
                          tracks: tracks)
    end

    albums
  end

  def collect_splitted_albums(path)
    albums = {}

    Dir.glob('**/*.{flac,ape,mp3}', base: path).each do |filename|
      file_path = File.join(path, filename)
      guessed_cue_path = file_path.gsub(File.extname(filename), '.cue')
      next if File.exist?(guessed_cue_path)

      track = build_track(file_path)

      if albums.key?(track.album)
        albums[track.album][:tracks] << track
      else
        album_path = File.dirname(file_path)
        cover_path = find_cover(album_path)

        album = Album.new(title: track.album,
                          artist: track.artist,
                          album_artist: nil,
                          genre: track.genre,
                          year: track.year,
                          path: album_path,
                          cover_path: cover_path,
                          tracks: [track])

        albums.store(album[:title], album)
      end
    end

    albums.values
  end

  def organize_classical_album(album, dst_path)
    split_album(album) unless album.cue_file_path.nil?
    album_paths = []
    errors = []

    album.tracks.each do |track|
      if File.exist?(track.path)
        work_title, part_title = track.title.split(' - ')

        track.title = part_title || work_title
        track.number = part_title.nil? ? 1 : get_classical_track_number(part_title)
        track.genre ||= album.genre
        track.album = work_title

        write_tags track
        album_path = File.join(dst_path, track.artist, track.album)
        album_paths << album_path unless album_paths.include?(album_path)
        FileUtils.mkdir_p(album_path) unless Dir.exist?(album_path)
        FileUtils.copy_file(track.path, File.join(album_path, "#{track.number}. #{track.title}.flac"))
      else
        errors << "[ERROR] File not found: #{track.path}"
      end
    end

    album_paths.each { |album_path| copy_cover(album, album_path) }
    errors.any? ? errors : :success
  end

  def organize_regular_album(album, dst_path)
    album_path = File.join(dst_path, album.artist, album.dir_name)
    FileUtils.mkdir_p album_path

    if album.cue_file_path.nil?
      album.tracks.each do |track|
        dst_file_name = "#{format('%02d', track.number)}. #{track.title}#{File.extname(track.path)}"
        dst_file_path = File.join(album_path, dst_file_name)
        FileUtils.copy_file(track.path, dst_file_path)
        # track.path = dst_file_path
        # write_tags track
      end
    else
      split_album(album, album_path)
    end

    copy_cover(album, album_path)
  end

  def split_album(album, dst_path = nil)
    dst_path ||= File.dirname(album.music_file_path)
    file_path = Shellwords.escape(album.music_file_path)
    cue_path = Shellwords.escape(album.cue_file_path)

    `shnsplit -f #{cue_path} -t '%n. %t' -o flac -O always -d #{Shellwords.escape(dst_path)} #{file_path}`

    album.tracks.each do |track|
      file_name = "#{format('%02d', track.number)}. #{track.title}.flac"
      track.path = File.join(dst_path, file_name)
      write_tags track
    end
  end

  def copy_music_files(file_names, src_path, dst_path)
    FileUtils.cd src_path

    file_names.each do |file_name|
      file_path = File.join src_path, file_name
      track = build_track file_path
      dst_file_name = "#{track.number}. #{track.title}#{File.extname(file_name)}"
      FileUtils.copy_file file_path, File.join(dst_path, dst_file_name)
    end
  end

  def find_cover(path)
    images = Dir.glob('**/*.{jpg,jpeg,png}', File::FNM_CASEFOLD, base: path)
    cover = images.find { |image| File.basename(image, '.*').match?(/cover|folder/) }
    cover ||= images.first
    File.join(path, cover) unless cover.nil?
  end

  def copy_cover(album, dst_path)
    return if album.cover_path.nil?

    file_name = "cover#{File.extname(album.cover_path).downcase}"
    FileUtils.cp(album.cover_path, File.join(dst_path, file_name))
  end

  def build_track(file_path)
    if File.extname(file_path) == '.flac'
      TagLib::FLAC::File.open(file_path) do |ref|
        tag = ref.xiph_comment || ref.tag

        Track.new artist: tag.artist,
                  album: tag.album,
                  year: tag.year,
                  number: tag.track,
                  title: tag.title,
                  genre: tag.genre,
                  path: file_path
      end
    else
      TagLib::FileRef.open(file_path) do |ref|
        unless ref.null?
          tag = ref.tag

          Track.new artist: tag.artist,
                    album: tag.album,
                    year: tag.year,
                    number: tag.track,
                    title: tag.title,
                    genre: tag.genre,
                    path: file_path
        end
      end
    end
  end

  def get_classical_track_number(title)
    roman_number = /^[IVX]+/.match(title)[0]
    ROMAN_NUMBERS.index(roman_number)&.next
  end

  def write_tags(track)
    TagLib::FileRef.open(track.path) do |file|
      unless file.null?
        file.tag.tap do |tag|
          tag.artist = track.artist
          tag.album = track.album
          tag.genre = track.genre
          tag.year = track.year unless track.year.nil?
          tag.title = track.title
          tag.track = track.number
        end
        file.save
      end
    end
  end
end
