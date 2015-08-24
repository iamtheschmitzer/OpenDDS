use strict;
use warnings;
use Date::Format;
use Cwd;
use LWP::Simple;
use File::Basename;


$ENV{TZ} = "UTC";

sub usage {
  return "gitrelease.pl <version> [options]\n" .
         "    version:  release version in a.b or a.b.c notation\n" .
         "options:\n" .
         "  --list          just show step names (default perform check)\n" .
         "  --remedy        remediate problems where possible\n" .
         "  --force         keep going where possible\n" .
         "  --remote=name   valid git remote for OpenDDS (default: origin)\n" .
         "  --step=#        # of individual step to run (default: all)\n" .
         "  --no-devguide   no devguide issued for this release"
}

sub email_announce_contents {
  my $settings = shift();
  my $devguide = "";
  if (!$settings->{nodevguide}) {
    $devguide =
      "An updated version of the OpenDDS Developer's Guide is available\n" .
      "from the same site in PDF format.\n";
  }

  my $result =
    "OpenDDS version $settings->{version} is now available for download.\n" .
    "Please see http://download.ociweb.com/OpenDDS for the download.\n\n" .
    $devguide . "\n" .
    "Updates in this OpenDDS version:\n\n";

  return $result;
}

sub news_contents_excerpt {
  return "";
}
############################################################################
sub parse_version {
  my $version = shift;
  my %result = ();
  if ($version =~ /([0-9])+\.([0-9])+\.?([0-9]+)?/) {
    $result{major} = $1;
    $result{minor} = $2;
    if ($3) {
      $result{micro} = $3;
    } else {
      $result{micro} = 0;
    }
  }
  return %result;
}

# Given a version string, return a numeric value for sorting purposes
sub version_to_value {
  my $tag_value = 0;
  my %result = parse_version(shift());
  if (%result) {
    $tag_value = (100.0 * ($result{major} || 0)) +
                          ($result{minor} || 0) +
                 ($result{micro} / 100.0);
  }
  return $tag_value;
}
############################################################################
sub verify_git_remote {
  my $settings = shift();
  my $remote = $settings->{remote};
  my $url = "";
  open(GITREMOTE, "git remote show $remote|");
  while (<GITREMOTE>) {
    if ($_ =~ /Push *URL: *(.*)$/) {
      $url = $1;
      last;
    }
  }
  close(GITREMOTE);
  return ($url eq $settings->{git_url});
}

sub message_git_remote {
  my $settings = shift;
  my $remote = $settings->{remote};
  return "Remote $remote does not match expected URL $settings->{git_url},\n" .
         "rerun and specifiy --remote";
}
############################################################################
sub verify_git_status_clean {
  my ($settings, $strict) = @_;
  my $version = $settings->{version};
  my $clean = 1;
  my $status = open(GITSTATUS, 'git status -s|');
  my $modified = $settings->{modified};

  my $unclean = "";
  while (<GITSTATUS>) {
    if (/^...(.*)/) {
      # If this is not a known modified file, or if we are in strict mode
      if ($strict || !$modified->{$1}) {
        $unclean .= $_;
        $clean = 0;
      }
    }
  }
  close(GITSTATUS);

  $settings->{unclean} = $unclean;
  return $clean;
}

sub message_git_status_clean {
  my $settings = shift;
  return "The working directory is not clean:\n" . $settings->{unclean} .
         "  Commit to source control, or run git clean before continuing."
}
############################################################################
sub verify_update_version_file {
  my $settings = shift();
  my $version = $settings->{version};
  my $correct = 0;
  my $status = open(VERSION, 'VERSION');
  my $metaversion = quotemeta($version);
  while (<VERSION>) {
    if ($_ =~ /This is OpenDDS version $metaversion, released/) {
      $correct = 1;
      last;
    }
  }
  close(VERSION);

  return $correct;
}

sub message_update_version_file {
  return "VERSION file needs updating with current version"
}

sub remedy_update_version_file {
  my $settings = shift();
  my $version = $settings->{version};
  print "  >> Updating VERSION file for $version\n";
  my $timestamp = $settings->{timestamp};
  my $outline = "This is OpenDDS version $version, released $timestamp";
  my $corrected = 0;
  open(VERSION, "+< VERSION")                 or die "Opening: $!";
  my $out = "";

  while (<VERSION>) {
    if (s/This is OpenDDS version [^,]+, released (.*)/$outline/) {
      $corrected = 1;
    }
    $out .= $_;
  }
  seek(VERSION,0,0)                        or die "Seeking: $!";
  print VERSION $out                       or die "Printing: $!";
  truncate(VERSION,tell(VERSION))          or die "Truncating: $!";
  close(VERSION)                           or die "Closing: $!";
  return $corrected;
}
############################################################################
sub find_previous_tag {
  my $settings = shift();
  my $remote = $settings->{remote};
  my $version = $settings->{version};
  my $prev_version_tag = "";
  my $prev_version_value = 0;
  my $release_version_value = version_to_value($version);

  open(GITTAG, "git tag --list 'DDS-*' |") or die "Opening $!";
  while (<GITTAG>) {
    chomp;
    my $tag_value = version_to_value($_);
    # If this is less than the release version, but the largest seen yet
    if (($tag_value < $release_version_value) &&
        ($tag_value > $prev_version_value)) {
      $prev_version_tag = $_;
      $prev_version_value = $tag_value;
    }
  }
  close(GITTAG);
  return $prev_version_tag;
}

sub verify_changelog {
  my $settings = shift();
  my $version = $settings->{version};
  my $status = open(CHANGELOG, $settings->{changelog});
  if ($status) {
    close(CHANGELOG);
  }
  return $status;
}

sub message_changelog {
  my $settings = shift();
  my $version = $settings->{version};
  return "File $settings->{changelog} missing";
}

sub remedy_changelog {
  my $settings = shift();
  my $version = $settings->{version};
  my $remote = $settings->{remote};
  my $prev_tag = find_previous_tag($settings);
  # Update so git log is correct
  open(GITREMOTE, "git remote update $remote|");
  while (<GITREMOTE>) {
  }
  close(GITREMOTE);
  my $author = 0;
  my $date = 0;
  my $comment = "";
  my $file_list = "";
  my $changed = 0;

  print "  >> Creating $settings->{changelog} from git history\n";

  open(CHANGELOG, ">$settings->{changelog}") or die "Opening $!";

  open(GITLOG, "git log $prev_tag..$remote/master --name-only |") or die "Opening $!";
  while (<GITLOG>) {
    chomp;
    if (/^commit .*/) {
      # print out previous
      if ($author) {
        print CHANGELOG $date . "  " .  $author . "\n";
        if ($file_list) {
          print CHANGELOG "\n" . $file_list;
        }
        print CHANGELOG "\n" . $comment . "\n";
        $comment = "";
        $file_list = "";
        $changed = 1;
      }
    } elsif (/^Merge: *(.*)/) {
      # Ignore
    } elsif (/^Author: *(.*)/) {
      $author = $1;
    } elsif (/^Date: *(.*)/) {
      $date = $1;
    } elsif (/^ +(.*) */) {
      $comment .= "$_\n";
    } elsif (/^([^ ]+.*) *$/) {
      $file_list .= " * $_\n";
    }
  }
  # print out final
  if ($author) {
    print CHANGELOG $date . "  " .  $author . "\n";
    if ($file_list) {
      print CHANGELOG "\n" . $file_list;
    }
    print CHANGELOG "\n" . $comment . "\n";
    $comment = "";
    $file_list = "";
    $changed = 1;
  }
  close(GITLOG);
  close(CHANGELOG);

  return $changed;
}
############################################################################
sub verify_news_file_section {
  my $settings = shift();
  my $version = $settings->{version};
  my $status = open(NEWS, 'NEWS');
  my $metaversion = quotemeta($version);
  my $has_version = 0;
  while (<NEWS>) {
    if ($_ =~ /Version $metaversion of OpenDDS\./) {
      $has_version = 1;
    }
  }
  close(NEWS);

  return ($has_version);
}

sub message_news_file_section {
  my $settings = shift();
  my $version = $settings->{version};
  return "NEWS file release $version section needs updating";
}

sub remedy_news_file_section {
  my $settings = shift();
  my $version = $settings->{version};
  print "  >> Adding $version section to NEWS\n";
  print "  !! Manual update to NEWS needed\n";
  my $timestamp = $settings->{timestamp};
  my $outline = "This is OpenDDS version $version, released $timestamp";
  open(NEWS, "+< NEWS")                 or die "Opening: $!";
  my $out = "Version $version of OpenDDS.\n" . <<"ENDOUT";

Additions:
  TODO: Add your features here

Fixes:
  TODO: Add your fixes here

ENDOUT

  $out .= join("", <NEWS>);
  seek(NEWS,0,0)                        or die "Seeking: $!";
  print NEWS $out                       or die "Printing: $!";
  truncate(NEWS,tell(NEWS))          or die "Truncating: $!";
  close(NEWS)                           or die "Closing: $!";
  return 1;
}
############################################################################
sub verify_update_news_file {
  my $settings = shift();
  my $version = $settings->{version};
  my $status = open(NEWS, 'NEWS');
  my $metaversion = quotemeta($version);
  my $has_version = 0;
  my $corrected_features = 1;
  my $corrected_fixes = 1;
  while (<NEWS>) {
    if ($_ =~ /Version $metaversion of OpenDDS\./) {
      $has_version = 1;
    } elsif ($_ =~ /TODO: Add your features here/) {
      $corrected_features = 0;
    } elsif ($_ =~ /TODO: Add your fixes here/) {
      $corrected_fixes = 0;
    }
  }
  close(NEWS);

  return ($has_version && $corrected_features && $corrected_fixes);
}

sub message_update_news_file {
  return "NEWS file needs updating with current version release notes";
}
############################################################################
sub verify_update_version_h_file {
  my $settings = shift();
  my $version = $settings->{version};
  my $matched_major  = 0;
  my $matched_minor  = 0;
  my $matched_micro  = 0;
  my $matched_version = 0;
  my $status = open(VERSION_H, 'dds/Version.h');
  my $metaversion = quotemeta($version);

  while (<VERSION_H>) {
    if ($_ =~ /^#define DDS_MAJOR_VERSION $settings->{major_version}$/) {
      ++$matched_major;
    } elsif ($_ =~ /^#define DDS_MINOR_VERSION $settings->{minor_version}$/) {
      ++$matched_minor;
    } elsif ($_ =~ /^#define DDS_MICRO_VERSION $settings->{micro_version}$/) {
      ++$matched_micro;
    } elsif ($_ =~ /^#define DDS_VERSION "$metaversion"$/) {
      ++$matched_version;
    }
  }
  close(VERSION_H);

  return (($matched_major == 1) && ($matched_minor   == 1) &&
          ($matched_micro == 1) && ($matched_version == 1));
}

sub message_update_version_h_file {
  return "dds/Version.h file needs updating with current version"
}

sub remedy_update_version_h_file {
  my $settings = shift();
  my $version = $settings->{version};
  print "  >> Updating dds/Version.h file for $version\n";
  my $corrected_major  = 0;
  my $corrected_minor  = 0;
  my $corrected_micro  = 0;
  my $corrected_version = 0;
  my $major_line = "#define DDS_MAJOR_VERSION $settings->{major_version}";
  my $minor_line = "#define DDS_MINOR_VERSION $settings->{minor_version}";
  my $micro_line = "#define DDS_MICRO_VERSION $settings->{micro_version}";
  my $version_line = "#define DDS_VERSION \"$settings->{version}\"";

  open(VERSION_H, "+< dds/Version.h")                 or die "Opening: $!";

  my $out = "";

  while (<VERSION_H>) {
    if (s/^#define DDS_MAJOR_VERSION +[0-9]+ *$/$major_line/) {
      ++$corrected_major;
    } elsif (s/^#define DDS_MINOR_VERSION +[0-9]+ *$/$minor_line/) {
      ++$corrected_minor;
    } elsif (s/^#define DDS_MICRO_VERSION +[0-9]+ *$/$micro_line/) {
      ++$corrected_micro;
    } elsif (s/^#define DDS_VERSION ".*" *$/$version_line/) {
      ++$corrected_version;
    }
    $out .= $_;
  }
  seek(VERSION_H,0,0)                        or die "Seeking: $!";
  print VERSION_H $out                       or die "Printing: $!";
  truncate(VERSION_H,tell(VERSION_H))        or die "Truncating: $!";
  close(VERSION_H)                           or die "Closing: $!";

  return (($corrected_major == 1) && ($corrected_minor   == 1) &&
          ($corrected_micro == 1) && ($corrected_version == 1));
}
############################################################################
sub verify_update_prf_file {
  my $settings = shift();
  my $version = $settings->{version};
  my $matched_header  = 0;
  my $matched_version = 0;
  my $status = open(PRF, 'PROBLEM-REPORT-FORM');
  my $metaversion = quotemeta($version);

  while (<PRF>) {
    if ($_ =~ /^This is OpenDDS version $metaversion, released/) {
      ++$matched_header;
    } elsif ($_ =~ /OpenDDS VERSION: $metaversion$/) {
      ++$matched_version;
    }
  }
  close(PRF);

  return (($matched_header == 1) && ($matched_version == 1));
}

sub message_update_prf_file {
  return "PROBLEM-REPORT-FORM file needs updating with current version"
}

sub remedy_update_prf_file {
  my $settings = shift();
  my $version = $settings->{version};
  print "  >> Updating PROBLEM-REPORT-FORM file for $version\n";
  my $corrected_header  = 0;
  my $corrected_version = 0;
  open(PRF, '+< PROBLEM-REPORT-FORM') or die "Opening $!";
  my $timestamp = $settings->{timestamp};
  my $header_line = "This is OpenDDS version $version, released $timestamp";
  my $version_line = "OpenDDS VERSION: $version";

  my $out = "";

  while (<PRF>) {
    if (s/^This is OpenDDS version .*, released.*$/$header_line/) {
      ++$corrected_header;
    } elsif (s/OpenDDS VERSION: .*$/$version_line/) {
      ++$corrected_version;
    }
    $out .= $_;
  }

  seek(PRF,0,0)                        or die "Seeking: $!";
  print PRF $out                       or die "Printing: $!";
  truncate(PRF,tell(PRF))              or die "Truncating: $!";
  close(PRF)                           or die "Closing: $!";

  return (($corrected_header == 1) && ($corrected_version == 1));
}
############################################################################
sub message_commit_git_changes {
  my $settings = shift();
  return "The working directory is not clean:\n" . $settings->{unclean} .
         "Changed files must be committed to git.";
}
############################################################################
sub verify_git_tag {
  my $settings = shift();
  my $found = 0;
  open(GITTAG, "git tag --list 'DDS-*' |") or die "Opening $!";
  while (<GITTAG>) {
    chomp;
    if (/$settings->{git_tag}/) {
      $found = 1;
    }
  }
  close(GITTAG);
  return $found;
}

sub message_git_tag {
  my $settings = shift();
  return "Could not find a tag of $settings->{git_tag}.\n" .
         "Create annotated tag using\n" .
         "  >> git tag -a -m 'OpenDDS Release $settings->{version}'" .
         $settings->{git_tag};
}

sub remedy_git_tag {
  my $settings = shift();
  print "Creating tag $settings->{git_tag}\n";
  my $command = "git tag -a -m 'OpenDDS Release $settings->{version}' " .
                 $settings->{git_tag};
  my $result = system($command);
  if (!$result) {
    print "Pushing tag to $settings->{remote}\n";
    $result = system("git push $settings->{remote} $settings->{git_tag}");
  }
  return !$result;
}
############################################################################
sub verify_clone_tag {
  my $settings = shift();
  my $correct = 0;
  if (-d $settings->{clone_dir}) {
    my $curdir = getcwd;
    chdir $settings->{clone_dir};
    open(GIT_BRANCH, "git branch |") or die "git branch $!";
    my $startwithstar = '$\*';
    while (<GIT_BRANCH>) {
      if (/^\* \(detached from $settings->{git_tag}\)/) {
        $correct = 1;
      }
    }
    close GIT_BRANCH;
    chdir $curdir;
  }
  return $correct;
}

sub message_clone_tag {
  my $settings = shift();
  if (-d $settings->{clone_dir}) {
    return "Directory $settings->{clone_dir} did not check out tag $settings->{git_tag}\n";
  } else {
    return "Could not see directory $settings->{clone_dir}\n";
  }
}

sub remedy_clone_tag {
  my $settings = shift();
  my $result = 0;
  if (!-d $settings->{clone_dir}) {
    print "Cloning OpenDDS into $settings->{clone_dir}\n";
    $result = system("git clone $settings->{git_url} $settings->{clone_dir}");
  }
  if (!$result) {
    my $curdir = getcwd;
    chdir($settings->{clone_dir});
    print "Checking out tag $settings->{git_tag}\n";
    $result = system("git checkout tags/$settings->{git_tag}");
    chdir($curdir);
  }
  return !$result;
}
############################################################################
sub verify_tgz_source {
  my $settings = shift();
  my $file = join("/", $settings->{parent_dir}, $settings->{tgz_src});
  my $good = 0;
  if (-f $file) {
    # Check if it is in the right format
    my $basename = basename($settings->{clone_dir});
    open(TGZ, "gzip -c -d $file | tar -tvf - |") or die "Opening $!";
    my $target = join("/", $basename, 'VERSION');
    while (<TGZ>) {
      if (/$target/) {
        $good = 1;
        last;
      }
    }
  }
  return $good;
}

sub message_tgz_source {
  my $settings = shift();
  my $file = join("/", $settings->{parent_dir}, $settings->{tgz_src});
  if (!-f $file) {
    return "Could not find file $file";
  } else {
    return "File $file is not in the right format";
  }
}

sub remedy_tgz_source {
  my $settings = shift();
  my $file = join("/", $settings->{parent_dir}, $settings->{tgz_src});
  my $curdir = getcwd;
  chdir($settings->{parent_dir});
  print "Creating file $settings->{tar_src}\n";
  my $basename = basename($settings->{clone_dir});
  my $result = system("tar -cf $settings->{tar_src} $basename --exclude-vcs");
  if (!$result) {
    print "Gzipping file $settings->{tar_src}\n";
    $result = system("gzip $settings->{tar_src}");
  }
  chdir($curdir);
  return !$result;
}
############################################################################
sub verify_zip_source {
  my $settings = shift();
  my $file = join("/", $settings->{parent_dir}, $settings->{zip_src});
  return (-f $file);
}

sub message_zip_source {
  my $settings = shift();
  my $file = join("/", $settings->{parent_dir}, $settings->{zip_src});
  return "Could not find file $file";
}

sub remedy_zip_source {
  my $settings = shift();
  my $file = join("/", $settings->{parent_dir}, $settings->{zip_src});
  my $curdir = getcwd;
  chdir($settings->{clone_dir});
  # zip -x .git .gitignore does not exclude as advertised
  print "Removing git-specific directories\n";
  my $result = system("find . -name '.git*' | xargs rm -rf");
  if (!$result) {
    print "Creating file $settings->{zip_src}\n";
    $result = system("zip ../$settings->{zip_src} -qq -r . -x '.git*'");
  }
  chdir($curdir);
  return !$result;
}
############################################################################
sub verify_md5_checksum{
  my $settings = shift();
  my $file = join("/", $settings->{parent_dir}, $settings->{md5_src});
  return (-f $file);
}

sub message_md5_checksum{
  return "You need to generate the MD5 checksum file";
}

sub remedy_md5_checksum{
  my $settings = shift();
  my $md5_file = join("/", $settings->{parent_dir}, $settings->{md5_src});
  my $tgz_file = join("/", $settings->{parent_dir}, $settings->{tgz_src});
  my $zip_file = join("/", $settings->{parent_dir}, $settings->{zip_src});
  system("md5sum $tgz_file $zip_file > $md5_file");
}
############################################################################
sub verify_gen_doxygen {
  return (-f 'html/dds/index.html');
}

sub message_gen_doxygen {
  return "Doxygen documentation needs generating";
}

sub remedy_gen_doxygen {
  my $generated = 0;
  if ($ENV{ACE_ROOT}) {
    $ENV{DDS_ROOT} = getcwd;
    my $result = system("$ENV{ACE_ROOT}/bin/generate_doxygen.pl", "-exclude_ace -include_dds");
    if (!$result) {
      $generated = 1;
    }
  } else {
    print "ACE_ROOT is not set\n";
  }
  return $generated;
}
############################################################################
sub verify_tgz_doxygen {
  my $settings = shift();
  my $file = join("/", $settings->{parent_dir}, $settings->{tgz_dox});
  my $good = 0;
  if (-f $file) {
    open(TGZ, "gzip -c -d $file | tar -tvf - |") or die "Opening $!";
    my $target = join("/", 'DDS', $settings->{changelog});
    while (<TGZ>) {
      if (/$target/) {
        $good = 1;
        last;
      }
    }
  }
  return $good;
}

sub message_tgz_doxygen {
  my $settings = shift();
  my $file = join("/", $settings->{parent_dir}, $settings->{tgz_dox});
  return "Could not find file $file";
}

sub remedy_tgz_doxygen {
  my $settings = shift();
  my $file = join("/", $settings->{parent_dir}, $settings->{tar_dox});
  my $curdir = getcwd;
  chdir($settings->{parent_dir});
  print "Creating file $settings->{tar_dox}\n";
  my $result = system("tar -cf $settings->{tar_dox} $curdir/html/dds");
  if (!$result) {
    print "Gzipping file $settings->{tar_dox}\n";
    $result = system("gzip $settings->{tar_dox}");
  }
  chdir($curdir);
  return !$result;
}
############################################################################
sub verify_zip_doxygen {
  my $settings = shift();
  my $file = join("/", $settings->{parent_dir}, $settings->{zip_dox});
  return (-f $file);
}

sub message_zip_doxygen {
  my $settings = shift();
  my $file = join("/", $settings->{parent_dir}, $settings->{zip_dox});
  return "Could not find file $file";
}

sub remedy_zip_doxygen {
  my $settings = shift();
  my $file = join("/", $settings->{parent_dir}, $settings->{zip_dox});
  my $curdir = getcwd;
  chdir($settings->{parent_dir});
  print "Creating file $settings->{zip_src}\n";
  my $result = system("zip -qq -r $settings->{zip_src} $curdir/html/dds");
  chdir($curdir);
  return !$result;
}
############################################################################
sub verify_ftp_upload {
  my $settings = shift();
  my $url = "http://download.ociweb.com/OpenDDS/";
  my $content = get($url);
  my $base = "OpenDDS-$settings->{version}";
  # Check for required files
  my @files = ("$base-doxygen.tar.gz", "$base-doxygen.zip",
               "$base.tar.gz",         "$base.zip",
               "$base.md5",            "OpenDDS-latest.pdf");
  if (!$settings->{nodevguide}) {
    push(@files , "$base.pdf");
  }
  foreach my $file (@files) {
    if ($content =~ /$file/) {
    } else {
      print "$file not found at $url\n";
      return 0;
    }
  }
  return 1;
}

sub message_ftp_upload {
  return "Release needs to be uploaded to ftp site";
}
############################################################################
sub verify_github_upload {
  my $settings = shift();
  my $tag = $settings->{git_tag};
  my $url = "https://github.com/objectcomputing/OpenDDS/releases/tag/$tag";
  my $content = get($url);
  my $base = "DDS-$settings->{version}";
  # Check for required files
  my @files = ("$base.tar.gz",         "$base.zip");
  foreach my $file (@files) {
    if ($content =~ /$file/) {
    } else {
      print "$file not found at $url\n";
      return 0;
    }
  }
  return 1;
}

sub message_github_upload {
  return "tar.gz and zip of sources need to be uploaded to github";
}
############################################################################
sub verify_update_opendds_org_front {
  my $settings = shift();
  my $url = "http://www.opendds.org";
  my $content = get($url);
  my $version = "[Vv]ersion $settings->{version}";
  if (!$content =~ /$version/) {
    return 0;
  }
}

sub message_update_opendds_org_front {
  return "OpenDDS.org front page needs updating";
}
############################################################################
sub verify_update_opendds_org_news {
  my $settings = shift();
  my $url = "http://www.opendds.org/news";
  my $content = get($url);
  my $version = "[Vv]ersion $settings->{version}";
  if (!$content =~ /$version/) {
    return 0;
  }
}

sub message_update_opendds_org_news {
  return "OpenDDS.org news page needs updating";
}
############################################################################
sub verify_email_list {
  # Can't verify
}

sub message_email_dds_release_announce {
  return 'Email needs to be sent to dds-release-announce@ociweb.com';
}

sub remedy_email_dds_release_announce {
  my $settings = shift;
  return 'Email this text to dds-release-announce@ociweb.com' . "\n\n" .

  "Approved: postthisrelease\n\n" .
  email_announce_contents($settings) .
  news_contents_excerpt($settings);
}

############################################################################
my @release_steps = (
  {
    title   => 'Verify git status is clean',
    skip    => 1,
    verify  => sub{verify_git_status_clean(@_, 0)},
    message => sub{message_git_status_clean(@_)}
  },
  {
    title   => 'Update VERSION',
    verify  => sub{verify_update_version_file(@_)},
    message => sub{message_update_version_file(@_)},
    remedy  => sub{remedy_update_version_file(@_)}
  },
  {
    title   => 'Update Version.h',
    verify  => sub{verify_update_version_h_file(@_)},
    message => sub{message_update_version_h_file(@_)},
    remedy  => sub{remedy_update_version_h_file(@_)}
  },
  {
    title   => 'Update PROBLEM-REPORT-FORM',
    verify  => sub{verify_update_prf_file(@_)},
    message => sub{message_update_prf_file(@_)},
    remedy  => sub{remedy_update_prf_file(@_)}
  },
  {
    title   => 'Verify remote arg',
    skip    => 1,
    verify  => sub{verify_git_remote(@_)},
    message => sub{message_git_remote(@_)},
  },
  {
    title   => 'Verify ChangeLog',
    verify  => sub{verify_changelog(@_)},
    message => sub{message_changelog(@_)},
    remedy  => sub{remedy_changelog(@_)}
  },
  {
    title   => 'Add NEWS Section',
    verify  => sub{verify_news_file_section(@_)},
    message => sub{message_news_file_section(@_)},
    remedy  => sub{remedy_news_file_section(@_)}
  },
  {
    title   => 'Update NEWS Section',
    verify  => sub{verify_update_news_file(@_)},
    message => sub{message_update_news_file(@_)}
  },
  {
    title   => 'Commit changes to GIT',
    verify  => sub{verify_git_status_clean(@_, 1)},
    message => sub{message_commit_git_changes(@_)}
  },
  {
    title   => 'Create git tag',
    verify  => sub{verify_git_tag(@_)},
    message => sub{message_git_tag(@_)},
    remedy  => sub{remedy_git_tag(@_)}
  },
  {
    title   => 'Clone tag',
    verify  => sub{verify_clone_tag(@_)},
    message => sub{message_clone_tag(@_)},
    remedy  => sub{remedy_clone_tag(@_)}
  },
  {
    title   => 'Create unix release archive',
    verify  => sub{verify_tgz_source(@_)},
    message => sub{message_tgz_source(@_)},
    remedy  => sub{remedy_tgz_source(@_)}
  },
  {
    title   => 'Create windows release archive',
    verify  => sub{verify_zip_source(@_)},
    message => sub{message_zip_source(@_)},
    remedy  => sub{remedy_zip_source(@_)}
  },
  {
    title   => 'Generate doxygen',
    verify  => sub{verify_gen_doxygen(@_)},
    message => sub{message_gen_doxygen(@_)},
    remedy  => sub{remedy_gen_doxygen(@_)} # $ACE_ROOT/bin/generate_doxygen.pl
  },
  {
    title   => 'Create unix doxygen archive',
    verify  => sub{verify_tgz_doxygen(@_)},
    message => sub{message_tgz_doxygen(@_)},
    remedy  => sub{remedy_tgz_doxygen(@_)}
  },
  {
    title   => 'Create windows doxygen archive',
    verify  => sub{verify_zip_doxygen(@_)},
    message => sub{message_zip_doxygen(@_)},
    remedy  => sub{remedy_zip_doxygen(@_)}
  },
  {
    title   => 'Create md5 checksum',
    verify  => sub{verify_md5_checksum(@_)},
    message => sub{message_md5_checksum(@_)},
    remedy  => sub{remedy_md5_checksum(@_)}
  },
  {
    title   => 'Upload to FTP Site',
    verify  => sub{verify_ftp_upload(@_)},
    message => sub{message_ftp_upload(@_)}
  },
  {
    title   => 'Upload to GitHub',
    verify  => sub{verify_github_upload(@_)},
    message => sub{message_github_upload(@_)}
   },
  {
    title   => 'Update opendds.org front page',
    verify  => sub{verify_update_opendds_org_front(@_)},
    message => sub{message_update_opendds_org_front(@_)}
  },
  {
    title   => 'Update opendds.org news page',
    verify  => sub{verify_update_opendds_org_news(@_)},
    message => sub{message_update_opendds_org_news(@_)}
  },
  {
    title   => 'Email DDS-Release-Announce list',
    verify  => sub{verify_email_list(@_)},
    message => sub{message_email_dds_release_announce(@_)},
    message => sub{remedy_email_dds_release_announce(@_)}
  }
);

my @t = gmtime;

sub any_arg_is {
  my $match = shift;
  foreach my $arg (@ARGV) {
    if ($arg eq $match) {
      return 1;
    }
  }
  return 0;
}

sub numeric_arg_value {
  my $name = shift;
  my @args = @ARGV[1..$#ARGV];
  my $arg_str = join(" ", @args);
  if ($arg_str =~ /$name ?=? ?([0-9]+)/) {
    return $1;
  }
}

sub string_arg_value {
  my $name = shift;
  my @args = @ARGV[1..$#ARGV];
  my $arg_str = join(" ", @args);
  if ($arg_str =~ /$name ?=? ?([^ ]+)/) {
    return $1;
  }
}

my $version = $ARGV[0] || "";
my %settings = (
  list       => any_arg_is("--list"),
  remedy     => any_arg_is("--remedy"),
  force      => any_arg_is("--force"),
  nodevguide => any_arg_is("--no-devguide"),
  step       => numeric_arg_value("--step"),
  remote     => string_arg_value("--remote") || "origin",
  version    => $version,
  git_tag    => "DDS-$version",
  clone_dir  => "../OpenDDS-Release-$version/OpenDDS-$version",
  parent_dir => "../OpenDDS-Release-$version",
  tar_src    => "OpenDDS-$version.tar",
  tgz_src    => "OpenDDS-$version.tar.gz",
  zip_src    => "OpenDDS-$version.zip",
  md5_src    => "OpenDDS-$version.md5",
  tar_dox    => "OpenDDS-$version-doxygen.tar",
  tgz_dox    => "OpenDDS-$version-doxygen.tar.gz",
  zip_dox    => "OpenDDS-$version-doxygen.zip",
  timestamp  => strftime("%a %b %e %T %Z %Y", @t),
  git_url    => 'git@github.com:objectcomputing/OpenDDS.git',
  changelog  => "docs/history/ChangeLog-$version",
  modified   => {"NEWS" => 1,
                "PROBLEM-REPORT-FORM" => 1,
                "VERSION" => 1,
                "dds/Version.h" => 1,
                "docs/history/ChangeLog-$version" => 1,
                "tools/scripts/gitrelease.pl" => 1}
);

my $half_divider = "-----------------------------------------";
my $divider = "$half_divider$half_divider";

sub run_step {
  my ($step_count, $step) = @_;
  # Output the title
  print "$step_count: $step->{title}\n";
  # Exit if we are just listing
  return if ($settings{list});
  # Run the verification
  if (!$step->{verify}(\%settings)) {
    # Failed
    print "$divider\n";
    print "  " . $step->{message}(\%settings) . "\n";

    my $remedied = 0;
    my $skipped  = 0;
    # If a remedy is available
    if ($step->{remedy}) {
      # If --remedy is set
      if ($settings{remedy}) {
        # Try remediation
        if (!$step->{remedy}(\%settings)) {
          print "  !!!! Remediation did not complete\n";
        # Reverify
        } elsif (!$step->{verify}(\%settings)) {
          print "  !!!! Remediation did not pass verification\n";
        } else {
          $remedied = 1;
        }
      # Else --remedy is  NOT set
      } elsif ($settings{force} && $step->{skip}) {
        $skipped = 1;
      } else {
        print "  Use --remedy to attempt a fix\n" if $step->{remedy};
      }

    # Else there is no remedy
    } elsif ($settings{force} && $step->{skip}) {
      $skipped = 1;
    } else {
      print "  Use --force to continue" if $step->{skip};
    }
    die unless ($remedied || $skipped);
    print "$divider\n";
  }
}

sub validate_version_arg {
  my $version = $settings{version} || "";
  my %result = parse_version($version);
  if (%result) {
    $settings{major_version} = $result{major};
    $settings{minor_version} = $result{minor};
    $settings{micro_version} = $result{micro};
    return 1;
  } elsif ($settings{list}) {
    return 1;
  } else {
    return 0;
  }
}

if ($settings{list} || validate_version_arg()) {
  if (my $step_num = $settings{step}) {
    # Run one step
    run_step($step_num, $release_steps[$step_num - 1]);
  } else {
    my $step_count = 0;

    for my $step (@release_steps) {
      ++$step_count;
      run_step($step_count, $step);
    }
  }
} else {
  print usage();
}
