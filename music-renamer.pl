#!/usr/bin/perl
#
# Copyright (c) 2007-2008 Sebastian Noack
#
# This program is free software; you can redistribute it and/or modify it
# under the terms of the GNU General Public License as published by the
# Free Software Foundation; either version 3 of the License, or (at your
# option) any later version.
#
# This program is distributed in the hope that it will be useful, but
# WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY
# or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License
# for more details.
#

use GStreamer -init;
use File::Spec::Functions;
use File::Basename;
use File::Temp;

# Global variables.
our $loop = Glib::MainLoop->new();
our $regex_forbidden_chars = qr/[\"\*\/:<>\?\\|]/;
our $regex_ending_slashes = qr/(\/\.*)*$/;
our $cur_filename;
our $cur_tempfile;
our $cur_pipeline;

my @paths;
my $mode = 'file';
my $pretend = 0;
my $verbose = 0;

# Parsing comandline args.
my $num_args = scalar(@ARGV);
if ($num_args > 0)
{
	for ($cur_arg = 0; $cur_arg < $num_args; $cur_arg++)
	{
		my $arg = $ARGV[$cur_arg];
		if ($arg eq '-h')
		{
			print_usage_and_exit();
		}
		elsif ($arg eq "-a")
		{
			$mode = "artist-dir";
		}
		elsif ($arg eq "-l")
		{
			$mode = "album-dir";
		}
		elsif ($arg eq "-f")
		{
			$mode = "file";
		}
		elsif ($arg eq '-p')
		{
			$pretend = 1;
		}
		elsif ($arg eq '-v')
		{
			$verbose = 1;
		}
		else
		{
			@paths = @ARGV[$cur_arg..$num_args-1];
			last;
		}
	}
}
else
{
	print_usage_and_exit();
}

# Setup signal handler.
$SIG{'INT'}  = \&exit_handler;
$SIG{'QUIT'} = \&exit_handler;

foreach $file_or_dir (@paths)
{
	if ($mode eq "file")
	{
		rename_file_on_tags($file_or_dir, $pretend, $verbose);
	}
	elsif ($mode eq "album-dir")
	{
		rename_dir_on_tags($file_or_dir, $pretend, $verbose);
	}
	elsif ($mode eq "artist-dir")
	{
	if (opendir(DIRHANDLE, $file_or_dir))
		{
			my $artist;
			foreach $albumdir (readdir(DIRHANDLE))
			{
				my $artistref = $artist ? undef : \$artist;
				rename_dir_on_tags(
					catfile($file_or_dir, $albumdir),
					$pretend,
					$verbose,
					$artistref) if (substr($albumdir, 0, 1) ne '.');
			}
			closedir(DIRHANDLE);

			rename_dir($file_or_dir, $artist, $pretend, $verbose) if ($artist);
		}
		else
		{
			warn "$file_or_dir is no directory.\n";
		}
	}
}

sub print_usage_and_exit ()
{
	print "Usage: $0 -a|l|f [-p] [-v] <path> ...\n\n";
	print "Modes:\n";
	print "-a               The given paths are artist directories, which contains further\n";
	print "                 directories representing the albums.\n";
	print "-l (ell)         The given paths are album directories, which contains the music\n";
	print "                 files.\n";
	print "-f               The given paths are music files (default).\n\n";
	print "Options:\n";
	print "--format=FORMAT  Specifies the format of the new filenames.\n";
	print "                 Default is \"{track} - {title}.{ext}\". Not yet supported!\n";
	print "-p               Just pretends the renaming, but does not really renames the\n";
	print "                 files and directories.\n";
	print "-v               Verbose output.\n";
	exit;
}

sub idle_exit_loop
{
	$loop->quit();
	return 0;
}

sub typefound_callback
{
	my ($element, $probability, $caps, $type) = @_;
	$$type = $caps->to_string();
	Glib::Idle -> add(\&idle_exit_loop);
}

sub newpad_callback
{
	my ($decoder, $pad, $last, $sink) = @_;
	$pad->link($sink->get_pad("sink"));
}

sub my_bus_callback
{
	my ($bus, $message, $tags) = @_;

	if ($message->type & "error" || $message->type & "eos")
	{
		$loop->quit();
	}
	elsif ($message->type & "tag")
	{
		my $new_tags = $message->tag_list();
		if (ref($$tags) eq "HASH")
		{
			@$$tags{keys %$new_tags} = values %$new_tags;
		}
		else
		{
			$$tags = $new_tags;
		}
	}

	return 1;
}

sub rename_dir
{
	($dirname, $newdirname, $pretend, $verbose) = @_;

	$dirname =~ s/$regex_ending_slashes//g;
	$newdirname =~ s/$regex_forbidden_chars//g;
	$newdirname = try_filename_from_unicode($newdirname);
	my $curdir = curdir();

	if ($dirname eq $curdir)
	{
		$dirname = catfile('..', basename(File::Spec->rel2abs($curdir)));
		$newdirname = catfile('..', $newdirname);
	}
	else
	{
		$newdirname = catfile(dirname($dirname), $newdirname);
	}

	print "$dirname => $newdirname\n"
		if ($verbose);
	rename ($dirname, $newdirname)
		unless ($pretend);
}

sub rename_dir_on_tags
{
	($dirname, $pretend, $verbose, $artist) = @_;

	if (opendir(DIRHANDLE, $dirname))
	{
		my $album;
		foreach $file (readdir(DIRHANDLE))
		{
			my $albumref = $album ? undef : \$album;
			rename_file_on_tags(
				catfile($dirname, $file),
				$pretend,
				$verbose,
				$artist,
				$albumref) if (substr($file, 0, 1) ne '.');
		}
		closedir(DIRHANDLE);

		rename_dir($dirname, $album, $pretend, $verbose) if ($album);
	}
	else
	{
		warn "$dirname is no directory.\n";
	}
}

sub find_type
{
	my ($filesrc) = @_;
	my $type;

	my $typefind = GStreamer::ElementFactory->make(typefind => "typefinder");
	$typefind->signal_connect(have_type => \&typefound_callback, \$type);

	$cur_pipeline = GStreamer::Pipeline->new("pipeline_find_type");
	$cur_pipeline->add($filesrc, $typefind);
	$filesrc->link($typefind);

	$loop->run() if ($cur_pipeline->set_state("paused") eq "success");
	
	$cur_pipeline->set_state("null");
	$cur_pipeline = undef;

	return $type;
}

sub read_tags
{
	my ($filesrc) = @_;
	my $tags;

	$cur_pipeline = GStreamer::Pipeline->new("pipeline_read_tags");
	my ($decoder, $sink) = GStreamer::ElementFactory->make(
		decodebin => "decoder",
		fakesink => "fakesink");

	$cur_pipeline->add($filesrc, $decoder, $sink);
	$filesrc->link($decoder);
	$decoder->signal_connect(new_decoded_pad => \&newpad_callback, $sink);

	$cur_pipeline->get_bus()->add_watch(\&my_bus_callback, \$tags);

	my $result =  $cur_pipeline->set_state("playing");
	if ($result eq "async")
	{
		($result, undef, undef) =
			$cur_pipeline->get_state(5 * GStreamer::GST_SECOND);
	}

	$loop->run() if ($result eq "success");
	
	$cur_pipeline->set_state("null");
	$cur_pipeline = undef;

	return $tags;
}

sub rename_file_on_tags
{
	my ($filename, $pretend, $verbose, $artist, $album) = @_;

	# Really evil hack, because of gstreamer-perl sucks.
	$cur_filename = $filename;
	$cur_tempfile = File::Temp::tempnam('.', undef);
	unless (rename($filename, $cur_tempfile))
	{
		omit_cur_filename ("Cannot rename $filename to $cur_tempfile: $!", 0);
		return;
	}

	my $filesrc = GStreamer::ElementFactory->make(filesrc => "source");
	$filesrc->set(location => $cur_tempfile);

	my $type = find_type($filesrc);
	unless ($type)
	{
		omit_cur_filename("Gstreamer can not read $cur_tempfile (formerly known as $filename).", 1);
		return;
	}

	my $tags = read_tags($filesrc);
	unless ($tags)
	{
		omit_cur_filename("Gstreamer can not read tags from $cur_tempfile (formerly known as $filename).", 1);
		return;
	}

	my $audio_codec = $tags->{'audio-codec'}[0];
	print 
	my $ext;
	if ($type eq "application/ogg")
	{
		$ext = "ogg";
	}
	if ($type eq "audio/x-flac")
	{
		$ext = "flac";
	}
	elsif ($type eq "audio/x-m4a")
	{
		$ext = "m4a";
	}
	elsif ($audio_codec eq "MPEG 1 Audio, Layer 3 (MP3)")
	{
		$ext = "mp3";
	}
	elsif ($audio_codec eq "Musepack")
	{
		$ext = "mpc";
	}
	elsif (substr($audio_codec, 0, 3) eq "WMA")
	{
		$ext = "wma";
	}
	else
	{
		omit_cur_filename("$filename has an unsupported mime-type ($type) or Codec ($audio_codec).", 1);
		return;
	}

	my $track = sprintf("%02d", $tags->{'track-number'}[0]);
	my $title = $tags->{'title'}[0];
	$$artist = $tags->{'artist'}[0] if ($artist);
	if ($album)
	{
		my $date = $tags->{'date'}[0];
		if ($date)
		{
			$$album = (((localtime($date)))[5] + 1900) . " - " . $tags->{'album'}[0];
		}
		else
		{
			$$album = $tags->{'album'}[0];
		}
	}

	my $newfilename = "$track - $title.$ext";
	$newfilename =~ s/$regex_forbidden_chars//g;
	$newfilename = try_filename_from_unicode($newfilename);
	$newfilename = catfile(dirname($filename), $newfilename);

	print "$filename => $newfilename\n"
		if ($verbose);

	my $warning;
	rename($cur_tempfile, $newfilename) || ($warning = "Cannot rename $cur_tempfile (formerly known as $filename) to $newfilename: $!")
		unless ($pretend);
	omit_cur_filename($warning, 1);
}

sub try_filename_from_unicode
{
	($filename) = @_;

	eval { $filename = Glib::filename_from_unicode($filename); };
	warn "Can not convert \"$filename\" to filesystem encoding.\n" if $@;

	return $filename;
}

sub omit_cur_filename
{
	my ($msg, $recover) = @_;
	rename($cur_tempfile, $cur_filename) if ($recover);
	$cur_filename = $cur_tempfile = undef;
	warn $msg . "\n" if ($msg);
}

sub exit_handler
{
	$cur_pipeline->set_state("null") if ($cur_pipeline);
	omit_cur_filename(undef, 1) if ($cur_tempfile);
	exit(0);
}
