#!/usr/bin/env python
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

import os
import sys
from optparse import OptionParser
import re

import tagpy

try:
	import mutagen.asf
except ImportError:
	pass
else:
	# Cast function to convert date strings from the tags to an integer
	# representing the year.
	year_to_int = lambda x: int(x.split(u'-', 1)[0])

	# Adapts the interface of tagpy's Tag object to mutagen's FileType object.
	class MutagenTagAdapter(object):
		def __init__(self, file, mapping):
			self._file = file
			self._mapping = mapping

		def __getattr__(self, name):
			try:
				type_cast, alias = self._mapping[name]
			except KeyError:
				raise AttributeError
			else:
				value = self._file.get(alias, u'')
				while not isinstance(value, unicode):
					if isinstance(value, (list, tuple)):
						value = value[0]
					else:
						value = unicode(value)

				try:
					return type_cast(value)
				except Exception:
					return None

		def isEmpty(self):
			for key in self._mapping.iterkeys():
				if getattr(self, key):
					return False
			return True

	# Implements tagpy's File object interface, for reading asf tags using mutagen.
	class AsfFile(object):
		def __init__(self, filename):
			self._file = mutagen.asf.Open(filename)

		def tag(self):
			return MutagenTagAdapter(self._file, {
				'album':  (unicode,     'WM/AlbumTitle'),
				'artist': (unicode,     'Author'),
				'title':  (unicode,     'Title'),
				'track':  (int,         'WM/TrackNumber'),
				'year':   (year_to_int, 'WM/Year'),
			})

	# Resolves file extensions that can't be handled by tagpy but by mutagen (at
	# the moment only wma).
	class MutagenResolver(tagpy.FileTypeResolver):
		def __init__(self):
			self._default_extensions = tagpy.FileRef._getExtToModule().keys()

		def createFile(self, filename, *args, **kwargs):
			ext = os.path.splitext(filename)[1][len(os.path.extsep):].lower()
			# If the extension is supported by the installed version of tagpy,
			# return None and let tagpy do the work, because of tagpy is known
			# to be faster than mutagen since it is written in C.
			if ext in self._default_extensions:
				return None

			# If the extension is supported by the mutagen bridge, return the
			# corresponding File object.
			if ext == 'wma':
				return AsfFile(filename)

	tagpy.FileRef.addFileTypeResolver(MutagenResolver())

def _default_format(vars):
	for tag in ('artist', 'album', 'title'):
		if not vars[tag]:
			raise vars['MusicRenamerFormatError']('No %s tag found in %%s' % tag)

	return os.path.join(
		u'%(artist)s',
		u'%s%%(album)s' % (vars['year'] and u'%(year)s - ' or u''),
		u'%s%%(title)s%s%%(ext)s' % ((vars['track'] and u'%(track).2i - ' or u''), os.path.extsep)
	) % vars

DEFAULT_FORMAT = _default_format

# Regular expression, that matches charecters not allowed in filenames.
re_forbidden_chars = re.compile(r'["\*\/:<>\?\\|]')

class MusicRenamerError(Exception):
	pass

def process_file(path, format=DEFAULT_FORMAT, verbose=False, pretend=False, encoding=None):
	# Read the tags from the given file.
	try:
		t = tagpy.FileRef(path).tag()
	except ValueError:
		raise MusicRenamerError('Taglib can not read %s.' % path)

	# Check if the file provides tags.
	if t.isEmpty():
		raise MusicRenamerError('No tags found in %s.' % path)

	# Collect the information, required to construct the ne filename.
	vars = {
		'artist': re_forbidden_chars.sub(u'', t.artist),
		'album': re_forbidden_chars.sub(u'', t.album),
		'title': re_forbidden_chars.sub(u'', t.title),
		'track': t.track,
		'year': t.year,
		'ext': unicode(os.path.splitext(path)[1][len(os.path.extsep):]).lower(),
	}

	# Construct the newfilename from either a callable or a format string.
	if callable(format):
		class MusicRenamerFormatError(MusicRenamerError):
			def __init__(self, message):
				try:
					super(MusicRenamerFormatError, self).__init__(message % path)
				except TypeError:
					super(MusicRenamerFormatError, self).__init__(message)
		vars[MusicRenamerFormatError.__name__] = MusicRenamerFormatError
		new_filename = format(vars)
	else:
		new_filename = format % vars

	# Convert the filename into filesystem encoding.
	new_filename = new_filename.encode(
		encoding or os.environ.get('G_FILENAME_ENCODING', 'utf-8'), 'ignore')

	# If not in pretend mode, rename/move the file to its new name/location.
	if not pretend:
		try:
			os.renames(path, new_filename)
		except OSError, e:
			raise MusicRenamerError(
				'Cannot rename %s to %s: %s' % (path, new_filename, e.strerror))

	if verbose:
		print '%s => %s' % (path, new_filename)

if __name__ == '__main__':
	usage = 'Usage: %prog <path> ...'
	parser = OptionParser(usage)
	parser.add_option('-r', '--recursive', action='store_true', default=False,
		dest='recursive', help='Search the path recursively to find files to rename')
	parser.add_option('--format', default=DEFAULT_FORMAT, dest='format',
		help=('Specifies the format of the new filenames. Default: '
			"'%(artist)/%(year)s - %(album)s)/%(track).2i - %(title)s.%(ext)s'"))
	parser.add_option('-p', '--pretend', action='store_true', default=False,
		dest='pretend', help=('Just pretends the renaming, but does not really '
			'renames the files and directories.'))
	parser.add_option('-q', '--quiet', action='store_false', default=True,
		dest='verbose', help="Don't print status messages.")

	options, args = parser.parse_args()
	if len(args) < 1:
		parser.error('You need to specify at least one path.')

	# Call process_file() for each path or each file under path if -r is given. 
	for path in args:
		if options.recursive:
			for dirpath, dirnames, filenames in os.walk(path):
				for filename in filenames:
					try:
						process_file(
							os.path.join(dirpath, filename),
							options.format,
							options.verbose,
							options.pretend)
					except MusicRenamerError, e:
						print e.message
		else:
			try:
				process_file(path, options.format, options.verbose, options.pretend) 
			except MusicRenamerError, e:
				print e.message
				sys.exit(1)
