require "music_organizer/version"

require 'taglib'
require 'rubycue'
require 'fileutils'
require 'shellwords'

module MusicOrganizer
  MergedAlbum = Struct.new(:cue_sheet, :cue_file_path, :music_file_path)
  TrackInfo = Struct.new(:artist, :album, :year, :number, :title, :genre, :path)
  ROMAN_NUMBERS = %w[I II III IV V VI VII VIII IX X].freeze

  module_function

  def structure_albums(path)
    parent_path = File.expand_path('..', path)
    merged_albums = collect_merged_albums path

    if merged_albums.any?
      merged_albums.each do |merged_album|
        if merged_album.cue_sheet.genre == 'Classical'
          split_classical_album merged_album, parent_path
        else
          split_regular_album merged_album, parent_path
        end
      end
    else
      music_files = Dir.glob('**/*.{flac,ape,mp3}', base: path)
      music_file_path = File.join(path, music_files.first)
      tag = get_track_info(music_file_path)
      album_dir_name = tag.year ? "#{tag.album} (#{tag.year})" : tag.album
      album_path = File.join(parent_path, tag.artist, album_dir_name)
      FileUtils.mkdir_p album_path
      copy_music_files music_files, path, album_path
      copy_cover path, album_path
    end

    true
  end

  def collect_merged_albums(path)
    albums = []

    Dir.glob('**/*.cue', base: path).each do |cue_file_name|
      cue_file_path = File.join(path, cue_file_name)
      cue_sheet = RubyCue::Cuesheet.new(File.read(cue_file_path))
      cue_sheet.parse!
      next if cue_sheet.file.nil?
      music_file_path = File.join(path, cue_sheet.file)
      next unless File.exist?(music_file_path)
      albums << MergedAlbum.new(cue_sheet, cue_file_path, music_file_path)
    end

    albums
  end

  def split_classical_album(merged_album, dst)
    FileUtils.cd File.dirname(merged_album.cue_file_path)
    split_file merged_album.music_file_path, merged_album.cue_file_path
    album_paths = []

    merged_album.cue_sheet.songs.each do |song|
      file_name = "#{format('%02d', song[:track])}. #{song[:title]}.flac"

      if File.exist? file_name
        artist = song[:performer]
        album, title = song[:title].split(' - ')
        number = get_classical_track_number(title)
        album_path = File.join(dst, artist, album)
        album_paths << album_path unless album_paths.include?(album_path)
        write_tags TrackInfo.new(artist, album, nil, number, title, 'Classical', file_name)
        FileUtils.mkdir_p(album_path) unless Dir.exist?(album_path)
        FileUtils.mv file_name, File.join(album_path, "#{number}. #{title}.flac")
      else
        puts "[ERROR] File not found: #{file_name}"
      end
    end

    album_paths.each { |album_path| copy_cover('.', album_path) }
  end

  def split_regular_album(album, dst)
    album_path = File.join(dst, album.cue_sheet.performer, album.cue_sheet.title)
    FileUtils.mkdir_p album_path
    FileUtils.cd album_path
    split_file album.music_file_path, album.cue_file_path
    copy_cover '.', album_path
  end

  def split_file(file, cue)
    cue = Shellwords.escape(cue)
    file = Shellwords.escape(file)
    `shnsplit -f #{cue} -t '%n. %t' -o flac -O always #{file}`

    # Creating tag metadata
    `cuetag #{cue} *.flac`
  end

  def copy_music_files(files, src, dst)
    FileUtils.cd src

    files.each do |file|
      file_path = File.join src, file
      track_info = get_track_info file_path
      dst_file_name = "#{track_info.number}. #{track_info.title}#{File.extname(file)}"
      FileUtils.copy_file file_path, File.join(dst, dst_file_name)
    end
  end

  def copy_cover(src, dst)
    images = Dir.glob('*.{jpg,jpeg,png}', base: src)
    FileUtils.cp(File.join(src, images.first), dst) if images.any?
  end

  def get_track_info(file_path)
    if File.extname(file_path) == '.flac'
      TagLib::FLAC::File.open(file_path) do |file|
        tag = file.xiph_comment || file.tag
        TrackInfo.new tag.artist, tag.album, tag.year, tag.track, tag.title, tag.genre, file_path
      end
    else
      TagLib::FileRef.open(file_path) do |ref|
        unless ref.null?
          tag = ref.tag
          TrackInfo.new tag.artist, tag.album, tag.year, tag.track, tag.title, tag.genre, file_path
        end
      end
    end
  end

  def get_classical_track_number(title)
    roman_number = /^[IVX]+/.match(title)[0]
    ROMAN_NUMBERS.index(roman_number)&.next
  end

  def write_tags(track_info)
    TagLib::FileRef.open(track_info.path) do |file|
      unless file.null?
        file.tag.tap do |tag|
          puts tag
          tag.artist = track_info.artist
          tag.album = track_info.album
          tag.year = track_info.year unless track_info.year.nil?
          tag.title = track_info.title
          tag.track = track_info.number
        end
        file.save
      end
    end
  end
end
