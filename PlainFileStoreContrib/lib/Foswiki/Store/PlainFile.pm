# See bottom of file for license and copyright information

=begin TML

---+ package Foswiki::Store::PlainFile

Single-file implementation of =Foswiki::Store= that uses normal
files in a standard directory structure to store versions.

   * Webs map to directories; webs only "exist" if they contain a preferences topic.
   * Topics are in data/.../topic.txt. If there is no .txt for a topic, the topic
     does not exist, even if there is a history.
   * Topic histories are in data/.../topic,pfv/
      * Each rev of the topic has a numbered file containing the text of that
        rev (1 2 3 etc) each with a corresponding metafile 1.m 2.m etc.
   * Attachment histories are in data/.../topic,pfv/ATTACHMENTS/attachmentname/
      * Each rev of an attachment has a numbered file containing the data for
        that rev (same as a topic), each with a corresponding metafile (same as a topic)
   * The latest rev always has a history file (note: this means that large attachments are
     stored twice; same as in the RCS stores)
   * 'date' always comes from the file modification date
   * 'author' and 'comment' come from the metafile
   * 'version' comes from the name of the version file

=cut

package Foswiki::Store::PlainFile;
use strict;
use warnings;

use File::Copy            ();
use File::Copy::Recursive ();
use Fcntl qw( :DEFAULT :flock );
use JSON ();

use Foswiki::Store ();
our @ISA = ('Foswiki::Store');

use Assert;
use Error qw( :try );

use Foswiki                                ();
use Foswiki::Store                         ();
use Foswiki::Meta                          ();
use Foswiki::Sandbox                       ();
use Foswiki::Iterator::NumberRangeIterator ();
use Foswiki::Users::BaseUserMapping        ();
use Foswiki::Serialise                     ();

my $wptn = "/$Foswiki::cfg{WebPrefsTopicName}.txt";

our $json = JSON->new->pretty(0);

BEGIN {

    # Import the locale for sorting
    if ( $Foswiki::cfg{UseLocale} ) {
        require locale;
        import locale();
    }
}

sub new {
    my $class = shift;
    my $this  = $class->SUPER::new(@_);

    # Compatibility with old config settings
    unless ( defined $Foswiki::cfg{Store}{filePermission} ) {
        $Foswiki::cfg{Store}{filePermission} =
          $Foswiki::cfg{RCS}{filePermission};
        $Foswiki::cfg{Store}{dirPermission} = $Foswiki::cfg{RCS}{dirPermission};
    }
    return $this;
}

sub finish {
    my $this = shift;
    $this->SUPER::finish();
    undef $this->{queryObj};
    undef $this->{searchQueryObj};
}

# Implement Foswiki::Store
sub readTopic {
    my ( $this, $meta, $version ) = @_;

    # check that the requested revision actually exists
    my @revs = ();
    my $nr = _numRevisions( \@revs, $meta );
    if ( defined $version && $version =~ /^\d+$/ ) {
        $version = $nr if ( $version == 0 || $version > $nr );
    }
    else {
        undef $version;

        # if it's a non-numeric string, we need to return undef
        # "...$version is defined but refers to a version that does
        # not exist, then $rev is undef"
    }

    my ( $text, $isLatest ) = _getRevision( \@revs, $meta, undef, $version );

    unless ( defined $text ) {
        ASSERT( not $isLatest ) if DEBUG;
        $meta->setLoadStatus( undef, $isLatest );
        return ( undef, $isLatest );
    }

    $text =~ s/\r//g;    # Remove carriage returns
                         # Parse meta-data out of the text
    Foswiki::Serialise::deserialise( $text, 'Embedded', $meta );

    $version = $isLatest ? $nr : $version;

    # Patch up the revision info with defaults. If the latest
    # file is more recent than the youngest history file, then
    # use these defaults too.
    my %ri;
    unless ( $isLatest && _latestIsNewer( \@revs, $meta ) ) {

        # The history metafile
        my $mf = _metaFile( $meta, undef, $version );
        ( $ri{author}, $ri{comment} ) = _readMetaFile($mf);
        $ri{date} = ( stat _historyFile( $meta, undef, $version ) )[9];
    }
    $ri{author} ||= $Foswiki::Users::BaseUserMapping::UNKNOWN_USER_CUID,
      $ri{version} ||= $version;
    $ri{date} ||= ( stat( _latestFile($meta) ) )[9];

    $meta->setRevisionInfo(%ri);

    # If there is a history, but the latest version of the topic
    # is out-of-date, then the author must be unknown to reflect
    # what happens on checking

    $meta->setLoadStatus( $version, $isLatest );
    return ( $version, $isLatest );
}

# Implement Foswiki::Store
sub moveAttachment {
    my ( $this, $oldTopicObject, $oldAtt, $newTopicObject, $newAtt, $cUID ) =
      @_;
    ASSERT($oldAtt) if DEBUG;
    ASSERT($newAtt) if DEBUG;

    # No need to save damage; we're not looking inside

    my $oldLatest = _latestFile( $oldTopicObject, $oldAtt );
    if ( -e $oldLatest ) {
        my $newLatest = _latestFile( $newTopicObject, $newAtt );
        _moveFile( $oldLatest, $newLatest );
        _moveFile(
            _historyDir( $oldTopicObject, $oldAtt ),
            _historyDir( $newTopicObject, $newAtt )
        );
        if ( $Foswiki::Store::STORE_FORMAT_VERSION < 1.2 ) {
            $this->recordChange(
                cuid          => $cUID,
                revision      => -1,
                verb          => 'update',
                oldpath       => $oldTopicObject->getPath(),
                oldattachment => $oldAtt,
                path          => $newTopicObject->getPath(),
                attachment    => $newAtt
            );
        }
    }
}

# Implement Foswiki::Store
sub copyAttachment {
    my ( $this, $oldTopicObject, $oldAtt, $newTopicObject, $newAtt, $cUID ) =
      @_;

    ASSERT($oldAtt) if DEBUG;
    ASSERT($newAtt) if DEBUG;

    # No need to save damage; we're not looking inside

    my $oldbase = _getPub($oldTopicObject);
    if ( -e "$oldbase/$oldAtt" ) {
        my $newbase = _getPub($newTopicObject);
        _copyFile(
            _latestFile( $oldTopicObject, $oldAtt ),
            _latestFile( $newTopicObject, $newAtt )
        );
        _copyFile(
            _historyDir( $oldTopicObject, $oldAtt ),
            _historyDir( $newTopicObject, $newAtt )
        );
        if ( $Foswiki::Store::STORE_FORMAT_VERSION < 1.2 ) {
            $this->recordChange(
                cuid       => $cUID,
                revision   => -1,
                verb       => 'insert',
                path       => $newTopicObject->getPath(),
                attachment => $newAtt
            );
        }
    }
}

# Implement Foswiki::Store
sub attachmentExists {
    my ( $this, $meta, $att ) = @_;

    ASSERT($att) if DEBUG;

    # No need to save damage; we're not looking inside
    return -e _latestFile( $meta, $att )
      || -e _historyFile( $meta, $att );
}

# Implement Foswiki::Store
sub moveTopic {
    my ( $this, $oldTopicObject, $newTopicObject, $cUID ) = @_;

    _saveDamage($oldTopicObject);

    my @revs;
    my $rev = _numRevisions( \@revs, $oldTopicObject );

    _moveFile( _latestFile($oldTopicObject), _latestFile($newTopicObject) );
    _moveFile( _historyDir($oldTopicObject), _historyDir($newTopicObject) );
    my $pub = _getPub($oldTopicObject);
    if ( -e $pub ) {
        _moveFile( $pub, _getPub($newTopicObject) );
    }
    if ( $Foswiki::Store::STORE_FORMAT_VERSION < 1.2 ) {
        if ( $newTopicObject->web ne $oldTopicObject->web ) {
            $this->recordChange(
                cuid     => $cUID,
                revision => $rev,
                verb     => 'update',
                oldpath  => $oldTopicObject->getPath(),
                path     => $newTopicObject->getPath()
            );
        }
        $this->recordChange(
            cuid     => $cUID,
            revision => $rev,
            verb     => 'update',
            oldpath  => $oldTopicObject->getPath(),
            path     => $newTopicObject->getPath()
        );
    }
}

# Implement Foswiki::Store
sub moveWeb {
    my ( $this, $oldWebObject, $newWebObject, $cUID ) = @_;

    # No need to save damage; we're not looking inside

    my $oldbase = _getData($oldWebObject);
    my $newbase = _getData($newWebObject);

    _moveFile( $oldbase, $newbase );

    $oldbase = _getPub($oldWebObject);
    if ( -e $oldbase ) {
        $newbase = _getPub($newWebObject);

        _moveFile( $oldbase, $newbase );
    }

    if ( $Foswiki::Store::STORE_FORMAT_VERSION < 1.2 ) {

      # We have to log in the new web, otherwise we would re-create the dir with
      # a useless .changes. See Item9278
        $this->recordChange(
            cuid     => $cUID,
            revision => -1,
            more     => 'Moved from ' . $oldWebObject->web,
            verb     => 'update',
            oldpath  => $oldWebObject->getPath(),
            path     => $newWebObject->getPath()
        );
    }
}

# Implement Foswiki::Store
sub testAttachment {
    my ( $this, $meta, $att, $test ) = @_;
    ASSERT($att) if DEBUG;
    my $fn = _latestFile( $meta, $att );
    return eval "-$test '$fn'";
}

# Implement Foswiki::Store
sub openAttachment {
    my ( $this, $meta, $att, $mode, @opts ) = @_;
    ASSERT($att) if DEBUG;
    return _openStream( $meta, $att, $mode, @opts );
}

# Implement Foswiki::Store
sub getRevisionHistory {
    my ( $this, $meta, $attachment ) = @_;

    unless ( -e _historyDir( $meta, $attachment ) ) {
        my @list = ();
        require Foswiki::ListIterator;
        if ( -e _latestFile( $meta, $attachment ) ) {
            push( @list, 1 );
        }
        return Foswiki::ListIterator->new( \@list );
    }
    my @revs;
    my $n = _numRevisions( \@revs, $meta, $attachment );

    return Foswiki::Iterator::NumberRangeIterator->new( $n, 1 );
}

# Implement Foswiki::Store
sub getNextRevision {
    my ( $this, $meta ) = @_;

    my @revs;
    return _numRevisions( \@revs, $meta ) + 1;
}

# Implement Foswiki::Store
sub getRevisionDiff {
    my ( $this, $meta, $rev2, $contextLines ) = @_;

    my $rev1 = $meta->getLoadedRev();
    my @list;
    my @revs;
    my ($text1) = _getRevision( \@revs, $meta, undef, $rev1 );
    my ($text2) = _getRevision( \@revs, $meta, undef, $rev2 );

    my $lNew = _split($text1);
    my $lOld = _split($text2);
    require Algorithm::Diff;
    my $diff = Algorithm::Diff::sdiff( $lNew, $lOld );

    foreach my $ele (@$diff) {
        push @list, $ele;
    }
    return \@list;
}

# Implement Foswiki::Store
sub getVersionInfo {
    my ( $this, $meta, $rev, $attachment ) = @_;

    my $df;
    my @revs;
    my $nr = _numRevisions( \@revs, $meta, $attachment );
    my $is_latest = 0;
    if ( $rev && $rev > 0 && $rev < $nr ) {
        $df = _historyFile( $meta, $attachment, $rev );
        unless ( -e $df ) {

            # May arise if the history is not continuous, or if
            # there is no history
            $df        = _latestFile( $meta, $attachment );
            $rev       = $nr;
            $is_latest = 1;
        }
    }
    else {
        $df        = _latestFile( $meta, $attachment );
        $rev       = $nr;
        $is_latest = 1;
    }
    my $info = {};
    unless ( $is_latest && _latestIsNewer( \@revs, $meta ) ) {

        # We can trust the history metafile
        my $mf = _metaFile( $meta, $attachment, $rev );
        ( $info->{author}, $info->{comment} ) = _readMetaFile($mf);
    }
    $info->{date} ||= _getTimestamp($df);
    $info->{version} = $rev;
    $info->{comment} = '' unless defined $info->{comment};
    $info->{author} ||= $Foswiki::Users::BaseUserMapping::UNKNOWN_USER_CUID;

    return $info;
}

# Implement Foswiki::Store
sub saveAttachment {

    # SMELL: $options not currently supported by the core
    my ( $this, $meta, $name, $stream, $cUID, $options ) = @_;

    ASSERT($name) if DEBUG;

    _saveDamage( $meta, $name );

    my @revs;
    my $rn = _numRevisions( \@revs, $meta, $name ) + 1;
    my $verb =
      ( $this->attachmentExists( $meta, $name ) ) ? 'update' : 'insert';

    my $latest = _latestFile( $meta, $name );
    _saveStream( $latest, $stream );
    my $hf = _historyFile( $meta, $name, $rn );
    _mkPathTo($hf);
    File::Copy::copy( $latest, $hf )
      or die "PlainFile: failed to copy $latest to $hf: $!";

    my $comment;
    if ( ref $options ) {
        if ( $options->{forcedate} ) {
            utime( $options->{forcedate}, $options->{forcedate},
                $latest )    # touch
              or die "PlainFile: could not touch $latest: $!";
            utime( $options->{forcedate}, $options->{forcedate}, $hf )
              or die "PlainFile: could not touch $hf: $!";
        }
        $comment = $options->{comment};
    }
    else {

        # Compatibility with old signature
        $comment = $options;
        $options = {};
    }

    my $mf = _metaFile( $meta, $name, $rn );
    _writeMetaFile( $mf, $cUID, $comment );

    return $rn;
}

# Implement Foswiki::Store
sub saveTopic {
    my ( $this, $meta, $cUID, $options ) = @_;

    _saveDamage($meta);

    my $verb = ( -e _latestFile($meta) ) ? 'update' : 'insert';
    my @revs;
    my $rn = _numRevisions( \@revs, $meta ) + 1;

    # Fix TOPICINFO
    my $ti = $meta->get('TOPICINFO');
    $ti->{version} = $rn;
    $ti->{date}    = $options->{forcedate} || time;
    $ti->{author}  = $cUID;

    # Create new latest
    my $latest = _latestFile($meta);
    _saveFile( $latest, Foswiki::Serialise::serialise( $meta, 'Embedded' ) );

    # Create history file by copying latest (modification date
    # doesn't matter, so long as it's >= $latest)
    my $hf = _historyFile( $meta, undef, $rn );
    _mkPathTo($hf);
    File::Copy::copy( $latest, $hf )
      or die "PlainFile: failed to copy $latest to $hf: $!";
    if ( $options->{forcedate} ) {
        utime( $options->{forcedate}, $options->{forcedate}, $latest )   # touch
          or die "PlainFile: could not touch $latest: $!";
        utime( $options->{forcedate}, $options->{forcedate}, $hf )       # touch
          or die "PlainFile: could not touch $hf: $!";
    }

    my $mf = _metaFile( $meta, undef, $rn );
    _writeMetaFile( $mf, $cUID, $options->{comment} );

    if ( $Foswiki::Store::STORE_FORMAT_VERSION < 1.2 ) {
        my $extra = $options->{minor} ? 'minor' : '';

        $this->recordChange(
            cuid     => $cUID,
            revision => $rn,
            more     => $extra,
            verb     => $verb,
            path     => $meta->getPath()
        );
    }

    return $rn;
}

# Implement Foswiki::Store
sub repRev {
    my ( $this, $meta, $cUID, %options ) = @_;

    _saveDamage($meta);

    my @revs;
    my $rn = _numRevisions( \@revs, $meta );
    ASSERT( $rn, $meta->getPath ) if DEBUG;
    my $latest = _latestFile($meta);
    my $hf     = _historyFile( $meta, undef, $rn );
    my $t      = ( stat $latest )[9];                 # SMELL: use TOPICINFO?
    unlink($hf);

    my $ti = $meta->get('TOPICINFO');
    $ti->{version} = $rn;
    $ti->{date}    = $options{forcedate} || time;
    $ti->{author}  = $cUID;

    _saveFile( $latest, Foswiki::Serialise::serialise( $meta, 'Embedded' ) );

    _mkPathTo($hf);
    File::Copy::copy( $latest, $hf )
      or die "PlainFile: failed to copy $latest to $hf: $!";
    my $mf = _metaFile( $meta, undef, $rn );
    _writeMetaFile( $mf, $cUID, $options{comment} );

    if ( $options{forcedate} ) {
        utime( $options{forcedate}, $options{forcedate}, $latest )    # touch
          or die "PlainFile: could not touch $latest: $!";
        utime( $options{forcedate}, $options{forcedate}, $hf )
          or die "PlainFile: could not touch $hf: $!";
    }

    if ( $Foswiki::Store::STORE_FORMAT_VERSION < 1.2 ) {
        $this->recordChange(
            cuid     => $cUID,
            revision => $rn,
            minor    => 1,
            comment  => 'reprev',
            verb     => 'update',
            path     => $meta->getPath()
        );
    }

    return $rn;
}

# Implement Foswiki::Store
sub delRev {
    my ( $this, $meta, $cUID ) = @_;

    _saveDamage($meta);

    my @revs;
    my $rev = _numRevisions( \@revs, $meta );
    if ( $rev <= 1 ) {
        die 'PlainFile: Cannot delete initial revision of '
          . $meta->web . '.'
          . $meta->topic;
    }

    my $hf = _historyFile( $meta, undef, $rev );
    unlink $hf;

    # Get the new top rev - which may or may not be -1, depending if
    # the history is complete or not
    @revs = ();
    my $cur = _numRevisions( \@revs, $meta );
    $hf = _historyFile( $meta, undef, $cur );
    my $thf = _latestFile($meta);

    # Copy it up to the latest file, then refresh the time on the history
    File::Copy::copy( $hf, $thf )
      or die "PlainFile: failed to copy to $thf: $!";
    utime( undef, undef, $hf )    # touch
      or die "PlainFile: could not touch $hf: $!";

    # reload the topic object
    $meta->unload();
    $meta->loadVersion();

    if ( $Foswiki::Store::STORE_FORMAT_VERSION < 1.2 ) {
        $this->recordChange(
            cuid     => $cUID,
            revision => $rev,
            verb     => 'update',
            path     => $meta->getPath()
        );
    }

    return $rev;
}

# Implement Foswiki::Store
sub atomicLockInfo {
    my ( $this, $meta ) = @_;
    my $filename = _getData($meta) . '.lock';
    if ( -e $filename ) {
        my $t = _readFile($filename);
        return split( /\s+/, $t, 2 );
    }
    return ( undef, undef );
}

# It would be nice to use flock to do this, but the API is unreliable
# (doesn't work on all platforms)
sub atomicLock {
    my ( $this, $meta, $cUID ) = @_;
    my $filename = _getData($meta) . '.lock';
    _saveFile( $filename, $cUID . "\n" . time );
}

# Implement Foswiki::Store
sub atomicUnlock {
    my ( $this, $meta, $cUID ) = @_;

    my $filename = _getData($meta) . '.lock';
    unlink $filename
      or die "PlainFile: failed to delete $filename: $!";
}

# Implement Foswiki::Store
sub webExists {
    my ( $this, $web ) = @_;

    return 0 unless defined $web;
    $web =~ s#\.#/#go;

    return 1 if ( -e _latestFile( $web, $Foswiki::cfg{WebPrefsTopicName} ) );

    #ASSERT(!-d _getData( $web ), $web) if DEBUG;
    return 0;
}

# Implement Foswiki::Store
sub topicExists {
    my ( $this, $web, $topic ) = @_;

    return 0 unless defined $web && $web ne '';
    $web =~ s#\.#/#go;
    return 0 unless defined $topic && $topic ne '';

    return -e _latestFile( $web, $topic )
      || -e _historyDir( $web, $topic );
}

# Implement Foswiki::Store
sub getApproxRevTime {
    my ( $this, $web, $topic ) = @_;

    return ( stat( _latestFile( $web, $topic ) ) )[9] || 0;
}

# Implement Foswiki::Store
# An attachment is only an attachment if it has a presence in the meta-data
sub eachAttachment {
    my ( $this, $meta ) = @_;

    my $dh;
    opendir( $dh, _attachmentsDir($meta) )
      or return new Foswiki::ListIterator( [] );
    my @list = grep { !/^[.*_]/ && !/,pfv$/ } readdir($dh);
    closedir($dh);

    require Foswiki::ListIterator;
    return new Foswiki::ListIterator( \@list );
}

# Implement Foswiki::Store
sub eachTopic {
    my ( $this, $meta ) = @_;

    my $dh;
    opendir( $dh, _getData( $meta->web ) )
      or return ();

    # the name filter is used to ensure we don't return filenames
    # that contain illegal characters as topic names.
    my @list =
      map { /^(.*)\.txt$/; $1; }
      sort
      grep { !/$Foswiki::cfg{NameFilter}/ && /\.txt$/ } readdir($dh);
    closedir($dh);

    require Foswiki::ListIterator;
    return new Foswiki::ListIterator( \@list );
}

# Implement Foswiki::Store
sub eachWeb {
    my ( $this, $meta, $all ) = @_;

    # Undocumented; this fn actually accepts a web name as well. This is
    # to make the recursion more efficient.
    my $web = ref($meta) ? $meta->web : $meta;

    my $dir = $Foswiki::cfg{DataDir};
    $dir .= '/' . $web if defined $web;
    my @list;
    my $dh;

    if ( opendir( $dh, $dir ) ) {
        @list = map {

            # Tradeoff: correct validation of every web name, which allows
            # non-web directories to be interleaved, thus:
            #    Foswiki::Sandbox::untaint(
            #           $_, \&Foswiki::Sandbox::validateWebName )
            # versus a simple untaint, much better performance:
            Foswiki::Sandbox::untaintUnchecked($_)
          }

          # The -e on the web preferences is used in preference to a
          # -d to avoid having to validate the web name each time. Since
          # the definition of a Web in this handler is "a directory with a
          # WebPreferences.txt in it", this works.
          grep { !/\./ && -e "$dir/$_$wptn" } readdir($dh);
        closedir($dh);
    }

    if ($all) {
        my $root = $web ? "$web/" : '';
        my @expandedList;
        while ( my $wp = shift(@list) ) {
            push( @expandedList, $wp );
            my $it = $this->eachWeb( $root . $wp, $all );
            push( @expandedList, map { "$wp/$_" } $it->all() );
        }
        @list = @expandedList;
    }
    @list = sort(@list);
    require Foswiki::ListIterator;
    return new Foswiki::ListIterator( \@list );
}

# Implement Foswiki::Store
sub remove {
    my ( $this, $cUID, $meta, $attachment ) = @_;
    my $f;
    if ( $meta->topic ) {

        # Topic or attachment
        unlink( _latestFile( $meta, $attachment ) );
        _rmtree( _historyDir( $meta, $attachment ) );
        _rmtree( _getPub($meta) ) unless ($attachment);    # topic only
    }
    else {

        # Web
        _rmtree( _getData($meta) );
        _rmtree( _getPub($meta) );
    }

    return unless ( $Foswiki::Store::STORE_FORMAT_VERSION < 1.2 );

    # Only log when deleting topics or attachment, otherwise we would re-create
    # an empty directory with just a .changes.
    if ($attachment) {
        $this->recordChange(
            cuid          => $cUID,
            revision      => -1,
            more          => 'Deleted attachment ' . $attachment,
            verb          => 'remove',
            oldpath       => $meta->getPath(),
            oldattachment => $attachment
        );
    }
    elsif ( my $topic = $meta->topic ) {
        $this->recordChange(
            cuid          => $cUID,
            revision      => -1,
            more          => 'Deleted ' . $topic,
            verb          => 'remove',
            oldpath       => $meta->getPath(),
            oldattachment => $attachment
        );
    }
}

# Implement Foswiki::Store
sub query {
    my ( $this, $query, $inputTopicSet, $session, $options ) = @_;

    my $engine;
    if ( $query->isa('Foswiki::Query::Node') ) {
        unless ( $this->{queryObj} ) {
            my $module = $Foswiki::cfg{Store}{QueryAlgorithm};
            eval "require $module";
            die
"Bad {Store}{QueryAlgorithm}; suggest you run configure and select a different algorithm\n$@"
              if $@;
            $this->{queryObj} = $module->new();
        }
        $engine = $this->{queryObj};
    }
    else {
        ASSERT( $query->isa('Foswiki::Search::Node') ) if DEBUG;
        unless ( $this->{searchQueryObj} ) {
            my $module = $Foswiki::cfg{Store}{SearchAlgorithm};
            eval "require $module";
            die
"Bad {Store}{SearchAlgorithm}; suggest you run configure and select a different algorithm\n$@"
              if $@;
            $this->{searchQueryObj} = $module->new();
        }
        $engine = $this->{searchQueryObj};
    }

    no strict 'refs';
    return $engine->query( $query, $inputTopicSet, $session, $options );
    use strict 'refs';
}

# Implement Foswiki::Store
sub getRevisionAtTime {
    my ( $this, $meta, $time ) = @_;

    my $hd = _historyDir($meta);
    my $d;
    unless ( opendir( $d, $hd ) ) {
        return 1 if ( $time >= ( stat( _latestFile($meta) ) )[9] );
        return undef;
    }
    my @revs;
    _loadRevs( \@revs, $hd );

    if ( _latestIsNewer( \@revs, $meta ) ) {
        return $revs[0] + 1
          if ( $time >= ( stat( _latestFile($meta) ) )[9] );
    }

    foreach my $rev ( reverse @revs ) {
        return $rev if ( $time >= ( stat("$hd/$rev") )[9] );
    }
    return undef;
}

# Implement Foswiki::Store
sub getLease {
    my ( $this, $meta ) = @_;

    my $filename = _getData($meta) . '.lease';
    my $lease;
    if ( -e $filename ) {
        my $t = _readFile($filename);
        $lease = { split( /\r?\n/, $t ) };
    }
    return $lease;
}

# Implement Foswiki::Store
sub setLease {
    my ( $this, $meta, $lease ) = @_;

    my $filename = _getData($meta) . '.lease';
    if ($lease) {
        _saveFile( $filename, join( "\n", %$lease ) );
    }
    elsif ( -e $filename ) {
        unlink $filename
          or die "PlainFile: failed to delete $filename: $!";
    }
}

# Implement Foswiki::Store
sub removeSpuriousLeases {
    my ( $this, $web ) = @_;
    my $webdir = _getData($web) . '/';
    if ( opendir( my $W, $webdir ) ) {
        foreach my $f ( readdir($W) ) {
            my $file = $webdir . $f;
            if ( $file =~ /^(.*)\.lease$/ ) {
                if ( !-e "$1,pfv" ) {
                    unlink($file);
                }
            }
        }
        closedir($W);
    }
}

#############################################################################
# PRIVATE FUNCTIONS
#############################################################################

# Get the absolute file path to a file in data. $what can be a Meta or
# a string path (e.g. a web name)
sub _getData {
    my ($what) = @_;
    my $path = $Foswiki::cfg{DataDir} . '/';
    return $path . $what unless ref($what);
    return $path . $what->web unless $what->topic;
    return $path . $what->web . '/' . $what->topic;
}

# Get the absolute file path to a file in pub. $what can be a Meta or
# a string path (e.g. a web name)
sub _getPub {
    my ($what) = @_;
    my $path = $Foswiki::cfg{PubDir} . '/';
    return $path . $what unless ref($what);
    return $path . $what->web unless $what->topic;
    return $path . $what->web . '/' . $what->topic;
}

# Load an array of the revisions stored in the given directory, sorted
# most recent (highest numbered) revision first.
sub _loadRevs {
    my ( $revs, $dir ) = @_;
    my $d;
    opendir( $d, $dir ) or die "PlainFile: '$dir': $!";

    # Read, untaint, sort in reverse
    @$revs = sort { $b <=> $a }
      map { /([0-9]+)/; $1 } grep { /^[0-9]+$/ } readdir($d);
    closedir($d);
}

# Get the absolute file path to the latest version of a topic or attachment
# _latestFile($meta [, $attachment])
#    - $meta is a Foswiki::Meta
# _latestFile( $web, $topic [, $attachment])
#    - web and topic are strings
sub _latestFile {
    my $p1 = shift;
    my $p2 = shift;

    unless ( ref($p1) ) {
        $p1 = "$p1/$p2";
        $p2 = shift;
    }
    return _getPub($p1) . "/$p2" if $p2;
    return _getData($p1) . ".txt";
}

# Get the absolute file path to the attachments metadir for a topic
sub _attachmentsDir {
    return _getData( $_[0] ) . ',pfv/ATTACHMENTS';
}

# Get the absolute file path to the history dir for a topic or attachment
# _historyDir($meta [, $attachment])
#    - $meta is a Foswiki::Meta
# _historyDir( $web, $topic [, $attachment])
#    - web and topic are strings
sub _historyDir {
    my $p1 = shift;
    my $p2 = shift;

    unless ( ref($p1) ) {
        $p1 = "$p1/$p2";
        $p2 = shift;
    }

    # $p1 is web/topic
    # $p2 is attachment name (if any)
    if ($p2) {

        # It's an attachment. The history is stored in the web data dir, in
        # a subdir with the same name as the topic and "extension" ,pfm
        # This keeps the pub directory "clean"; a requirement when these
        # files are visible via a web interface.
        return _attachmentsDir($p1) . "/${p2}";
    }
    else {

        # It's a topic. The history is stored in the web data dir.
        return _getData($p1) . ",pfv";
    }
}

# Get the absolute file path to the history for a topic or attachment
# _historyFile($meta, $attachment, $version)
#    - $meta is a Foswiki::Meta
# _historyFile( $web, $topic, $attachment, $version)
#    - web and topic are strings
sub _historyFile {
    my $ver = pop;
    return _historyDir(@_) . "/$ver";
}

# Get the absolute file path to the metafile for a topic or attachment
# _metaFile($meta, $attachment, $version)
#    - $meta is a Foswiki::Meta
# _metaFile( $web, $topic, $attachment, $version)
#    - web and topic are strings
sub _metaFile {
    return _historyFile(@_) . '.m';
}

# Get the number of revisions for a topic or attachment
sub _numRevisions {
    my ( $revs, $meta, $attachment ) = @_;

    return 0 unless -e _latestFile( $meta, $attachment );

    my $dir = _historyDir( $meta, $attachment );

    # we know that if there is no history
    # then only rev 1 exists
    return 1 unless -e $dir;

    _loadRevs( $revs, $dir ) unless scalar @$revs;
    return 1 unless scalar @$revs;    # one implicit revision

    # If the head revision is inconsistent with the history,
    # then there's another implicit revision
    if ( _latestIsNewer( $revs, $meta, $attachment ) ) {
        unshift( @$revs, $revs->[0] + 1 );
    }
    return $revs->[0];
}

# If a latest file has a more recent file date than the corresponding
# history, then save the damage.
# This is required because in a filesystem store the latest file may
# be modified by an external process, so that it is no longer
# consistent with the history. This condition is detected by a history
# file that is older than the latest file.
# This could be made a NOP if we  treated the latest as the most recent
# revision, and don't store a history for it until it is replaced.
# However that would require moving meta-data out of band, because the
# latest would still contain an author who was not the correct author.
# Of course you may not care that the author is not modified by external
# processes.....
sub _saveDamage {
    my ( $meta, $attachment ) = @_;
    my $d;

    my $latest = _latestFile( $meta, $attachment );
    return unless ( -e $latest );

    if ( -e "$latest,v" && !$Foswiki::inUnitTestMode ) {
        die <<DONE;
PlainFileStore is selected but you have ,v files present in the directory tree, Save aborted to avoid loss of topic history.
Did you remember to convert the store?  The administrator should review tools/change_store.pl,  or select an RCS based store.

DONE
    }

    my @revs;
    my $rev = _latestIsNewer( \@revs, $meta, $attachment, $latest );
    return unless $rev;

    # No existing revs; create
    # If this is a topic, correct the TOPICINFO
    unless ($attachment) {
        my $t = _readFile($latest);

        $t =~ s/^%META:TOPICINFO{(.*)}%$//m;
        $t =
            '%META:TOPICINFO{author="'
          . $Foswiki::Users::BaseUserMapping::UNKNOWN_USER_CUID
          . '" comment="autosave" date="'
          . time()
          . '" format="1.1" version="'
          . $rev . '"}%' . "\n$t";
        _saveFile( $latest, $t );

        # Creating the history second ensures it is more recent than the
        # latest.
    }

    my $hf = _historyFile( $meta, $attachment, $rev );
    _mkPathTo($hf);
    File::Copy::copy( $latest, $hf )
      or die "PlainFile: failed to copy to $hf: $!";
}

# Return 0 if the latest is consistent with the history or
# there is no history. If there is a history and the working
# file is newer, then return the rev that would be created
# if we checked in.
sub _latestIsNewer {
    my ( $revs, $meta, $attachment, $latest ) = @_;

    $latest ||= _latestFile( $meta, $attachment );

    my $hd = _historyDir( $meta, $attachment );
    return 1 unless ( -e $hd );

    _loadRevs( $revs, $hd ) unless scalar(@$revs);
    return 0 unless scalar(@$revs);    # no history

    my $topRev = $revs->[0];
    my $hf     = "$hd/$topRev";

    # Check the time on the history file; is the .txt newer?
    my $ht = ( stat($hf) )[9] || time;
    my $lt = ( stat($latest) )[9];
    return 0 if ( $ht >= $lt );        # up to date
    return $topRev + 1;                # we must create this
}

sub _readMetaFile {
    my $mf = shift;
    return () unless -e $mf;
    return split( "\n", _readFile($mf), 2 );
}

sub _writeMetaFile {
    my $mf = shift;
    _mkPathTo($mf);
    _saveFile( $mf, join( "\n", map { defined $_ ? $_ : '' } @_ ) );
}

sub _readChanges {
    my ( $file, $web ) = @_;

    my $all_lines = Foswiki::Sandbox::untaintUnchecked( _readFile($file) );

    # Look at the first line to deduce format
    if ( $all_lines =~ /^\[/s ) {
        my $changes = $json->decode($all_lines);

        print STDERR "Corrupt $file: $@\n" if ($@);
        foreach my $entry (@$changes) {
            if ( $entry->{path} && $entry->{path} =~ /^(.*)\.(.*)$/ ) {
                $entry->{topic} = $2;
            }
            elsif ( $entry->{oldpath} && $entry->{oldpath} =~ /^(.*)\.(.*)$/ ) {
                $entry->{topic} = $2;
            }
            $entry->{user} =
                $Foswiki::Plugins::SESSION
              ? $Foswiki::Plugins::SESSION->{users}
              ->getWikiName( $entry->{cuid} )
              : $entry->{cuid};
            $entry->{more} =
              ( $entry->{minor} ? 'minor ' : '' ) . ( $entry->{comment} || '' );
        }
        return @$changes;
    }

    # Decode the mess that was the old changes format
    my @changes;
    foreach my $line ( split( /[\r\n]+/, $all_lines ) ) {
        my @row = split( /\t/, $line );

        # Old (pre 1.2) format

        # Create a hash for this line
        my %row = (
            topic => Foswiki::Sandbox::untaint(
                $row[0], \&Foswiki::Sandbox::validateTopicName
            ),
            user     => $row[1],
            time     => $row[2] || 0,
            revision => $row[3] || 1,
            more     => $row[4] || '',
        );

        # Fill in 1.2 fields
        if ( $row{revision} > 1 ) {
            $row{verb} = 'update';
        }
        else {
            $row{verb} = 'insert';
        }
        $row{minor} = ( $row{more} =~ /minor/ );
        $row{cuid} =
            $Foswiki::Plugins::SESSION
          ? $Foswiki::Plugins::SESSION->{users}
          ->getCanonicalUserID( $row{user} )
          : $row{user};
        $row{path} = $web;
        $row{path} .= ".$row{topic}" if $row{topic};
        $row{comment} = $row{more};
        if ( $row{more} =~ /Moved from (\w+)/ ) {
            $row{oldpath} = $1;
        }
        if ( $row{more} =~ /Deleted attachment (\S+)/ ) {
            $row{attachment} = $1;
        }
        unshift( @changes, \%row );
    }
    return @changes;
}

# Record a change in the web history
sub recordChange {
    my ( $this, %args ) = @_;

    if (DEBUG) {
        if ( $Foswiki::Store::STORE_FORMAT_VERSION < 1.2 ) {
            ASSERT( ( caller || 'undef' ) eq __PACKAGE__ );
        }
        else {
            ASSERT( ( caller || 'undef' ) ne __PACKAGE__ );
        }
        ASSERT( $args{verb} );
        ASSERT( $args{cuid} );
        ASSERT( $args{revision} );
        ASSERT( $args{path} );
        ASSERT( !defined $args{more} );
        ASSERT( !defined $args{user} );
    }

    #    my ( $meta, $cUID, $rev, $more ) = @_;
    #    $more ||= '';

    # Support for Foswiki < 1.2

    my $web = $args{path};
    if ( $web =~ /\./ ) {
        ($web) = Foswiki->normalizeWebTopicName( undef, $web );
    }

    # Can't log changes in a non-existent web
    return unless ( -d _getData($web) );

    my $file = _getData($web) . '/.changes';
    my @changes;
    if ( -e $file ) {
        @changes = _readChanges( $file, $web );

        # Trim old entries
        my $cutoff = time - $Foswiki::cfg{Store}{RememberChangesFor};
        while ( scalar(@changes) && $changes[0]->{time} < $cutoff ) {
            shift(@changes);
        }
    }

    # Add the new change to the end of the file
    $args{time} = time;
    push( @changes, \%args );
    _saveFile( $file, $json->encode( \@changes ) );
}

# Implement Foswiki::Store
sub eachChange {
    my ( $this, $meta, $since ) = @_;

    my $file = "$Foswiki::cfg{DataDir}/" . $meta->web . "/.changes";
    require Foswiki::ListIterator;

    my @changes;
    if ( -r $file ) {
        @changes = reverse grep { $_->{time} >= $since } _readChanges($file);
    }
    return Foswiki::ListIterator->new( \@changes );
}

# Read an entire file
sub _readFile {
    my ($name) = @_;

    my $data;
    my $IN_FILE;
    open( $IN_FILE, '<', $name )
      or die "PlainFile: failed to read $name: $!";
    binmode($IN_FILE);
    local $/ = undef;
    $data = <$IN_FILE>;
    close($IN_FILE);
    $data = '' unless defined $data;
    return $data;
}

# Open a stream onto a file
sub _openStream {
    my ( $meta, $att, $mode, %opts ) = @_;
    my $stream;

    my $path;
    my @revs;
    if (   $opts{version}
        && $opts{version} < _numRevisions( \@revs, $meta, $att ) )
    {
        ASSERT( $mode !~ />/ ) if DEBUG;
        $path = _historyFile( $meta, $att, $opts{version} );
    }
    else {
        $path = _latestFile( $meta, $att );
        _mkPathTo($path) if ( $mode =~ />/ );
    }
    unless ( open( $stream, $mode, $path ) ) {
        die("PlainFile: open stream $mode '$path' failed: $!");
    }
    binmode $stream;
    return $stream;
}

# Save a file
sub _saveFile {
    my ( $file, $text ) = @_;
    _mkPathTo($file);
    my $fh;
    open( $fh, '>', $file )
      or die("PlainFile: failed to create file $file: $!");
    flock( $fh, LOCK_EX )
      or die("PlainFile: failed to lock file $file: $!");
    binmode($fh)
      or die("PlainFile: failed to binmode $file: $!");
    print $fh $text
      or die("PlainFile: failed to print into $file: $!");
    close($fh)
      or die("PlainFile: failed to close file $file: $!");

    chmod( $Foswiki::cfg{Store}{filePermission}, $file );

    return;
}

# Save a stream to a file
sub _saveStream {
    my ( $file, $fh ) = @_;

    _mkPathTo($file);
    my $F;
    open( $F, '>', $file ) or die "PlainFile: open $file failed: $!";
    binmode($F) or die "PlainFile: failed to binmode $file: $!";
    my $text;
    while ( read( $fh, $text, 1024 ) ) {
        print $F $text;
    }
    close($F) or die "PlainFile: close $file failed: $!";

    chmod( $Foswiki::cfg{Store}{filePermission}, $file );
}

# Move a file or directory from one absolute file path to another.
# if the destination already exists it's an error.
sub _moveFile {
    my ( $from, $to ) = @_;
    die "PlainFile: move target $to already exists" if -e $to;
    _mkPathTo($to);
    my $ok;
    if ( -d $from ) {
        $ok = File::Copy::Recursive::dirmove( $from, $to );
    }
    else {
        ASSERT( -e $from, $from ) if DEBUG;
        $ok = File::Copy::move( $from, $to );
    }
    $ok or die "PlainFile: move $from to $to failed: $!";
}

# Copy a file or directory from one absolute file path to another.
# if the destination already exists it's an error.
sub _copyFile {
    my ( $from, $to ) = @_;

    die "PlainFile: move target $to already exists" if -e $to;
    _mkPathTo($to);
    my $ok;
    if ( -d $from ) {
        $ok = File::Copy::Recursive::dircopy( $from, $to );
    }
    else {
        $ok = File::Copy::copy( $from, $to );
    }
    $ok or die "PlainFile: copy $from to $to failed: $!";
}

# Make all directories above the path
sub _mkPathTo {
    my $file = shift;

    ASSERT( File::Spec->file_name_is_absolute($file) ) if DEBUG;

    my ( $volume, $path, undef ) = File::Spec->splitpath($file);
    $path = File::Spec->catpath( $volume, $path, '' );

    # SMELL:  Sites running Apache with SuexecUserGroup will
    # have a forced "safe" umask. Override umask here to allow
    # correct dirPermissions to be applied
    umask( oct(777) - $Foswiki::cfg{Store}{dirPermission} );

    eval {
        File::Path::mkpath( $path, 0, $Foswiki::cfg{Store}{dirPermission} );
    };
    if ($@) {
        die("PlainFile: failed to create ${path}: $!");
    }
}

# Remove an entire directory tree
sub _rmtree {
    my $root = shift;
    my $D;
    if ( opendir( $D, $root ) ) {
        foreach my $entry ( grep { !/^\.+$/ } readdir($D) ) {
            $entry =~ /^(.*)$/;
            $entry = $root . '/' . $1;
            if ( -d $entry ) {
                _rmtree($entry);
            }
            elsif ( !unlink($entry) && -e $entry ) {
                if ( $Foswiki::cfg{OS} ne 'WINDOWS' ) {
                    die "PlainFile: Failed to delete file $entry: $!";
                }
                else {

                    # Windows sometimes fails to delete files when
                    # subprocesses haven't exited yet, because the
                    # subprocess still has the file open. Live with it.
                    warn "WARNING: Failed to delete file $entry: $!";
                }
            }
        }
        closedir($D);

        if ( !rmdir($root) ) {
            if ( $Foswiki::cfg{OS} ne 'WINDOWS' ) {
                die "PlainFile: Failed to delete $root: $!";
            }
            else {
                warn "WARNING: Failed to delete $root: $!";
            }
        }
    }
}

# Get the timestamp on a file. 0 indicates the file was not found.
sub _getTimestamp {
    my ($file) = @_;

    my $date = 0;
    if ( -e $file ) {

        # If the stat fails, stamp it with some arbitrary static
        # time in the past (00:40:05 on 5th Jan 1989)
        $date = ( stat $file )[9] || 600000000;
    }
    return $date;
}

# Get a specific revision of a topic or attachment
sub _getRevision {
    my ( $revs, $meta, $attachment, $version ) = @_;

    my $nr = _numRevisions( $revs, $meta, $attachment );
    if ( $nr && $version && $version <= $nr ) {
        my $fn = _historyDir( $meta, $attachment ) . "/$version";
        if ( -e $fn ) {
            return ( _readFile($fn), $version == $nr );
        }
    }
    my $latest = _latestFile( $meta, $attachment );
    return ( undef, 0 ) unless -e $latest;

    # no version given, give latest (may not be checked in yet)
    return ( _readFile($latest), 1 );
}

# Split a string on \n making sure we have all newlines. If the string
# ends with \n there will be a '' at the end of the split.
sub _split {

    #my $text = shift;

    my @list = ();
    return \@list unless defined $_[0];

    my $nl = 1;
    foreach my $i ( split( /(\n)/o, $_[0] ) ) {
        if ( $i eq "\n" ) {
            push( @list, '' ) if $nl;
            $nl = 1;
        }
        else {
            push( @list, $i );
            $nl = 0;
        }
    }
    push( @list, '' ) if ($nl);

    return \@list;
}

1;
__END__
Foswiki - The Free and Open Source Wiki, http://foswiki.org/

Copyright (C) 2012 Crawford Currie http://c-dot.co.uk

This program is free software; you can redistribute it and/or
modify it under the terms of the GNU General Public License
as published by the Free Software Foundation; either version 2
of the License, or (at your option) any later version. For
more details read LICENSE in the root of this distribution.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.

As per the GPL, removal of this notice is prohibited.
