package Device;
use LWP::UserAgent;
use HTTP::Request::Common;
use XML::Bare;
use IO::Socket::SSL;
use Digest::SHA qw/sha512/;
use URI;
use v5.10;
use strict;
no warnings 'experimental';

my $ua = LWP::UserAgent->new;
$ua->agent('QNXWebClient/1.0');
$ua->cookie_jar({
	file => 'cookies.txt',
	autosave => 1,
});
$ua->ssl_opts( verify_hostname => 0 );
$ua->ssl_opts( SSL_ca_file => 'cert.pem' );

sub new {
	my ($class, @args) = @_;
	my $obj = { @args };

	return bless $obj, $class;
}

sub xml_status {
	my ($content, $action) = @_;

	my $xml = XML::Bare->new(text => $content);
	my $tree = $xml->parse()->{RimTabletResponse}->{$action};
	return wantarray ? ($tree->{Status}->{value}, $tree) : $tree->{Status}->{value};
}

sub discover {
	my ($self) = @_;

	my $res = $ua->get("http://$self->{ip}/cgi-bin/discovery.cgi");
	if ($res->is_success) {
		say $res->decoded_content;
		return 1;
	} else {
		say $res->status_line;
	}
}

sub logged_in {
	my ($self) = @_;

	my $res = $ua->get("https://$self->{ip}/cgi-bin/login.cgi?request_version=3");
	if (!$res->is_success) {
		say $res->status_line;
		return;
	}

	if (xml_status($res->decoded_content, 'Auth') eq 'Success') {
		return {
			logged_in => 1,
		};
	} elsif (xml_status($res->decoded_content, 'AuthChallenge') eq 'Error') {
		say "Invalid cookie, clearing and retrying...";
		$ua->cookie_jar->clear;
		return $self->logged_in;
	} else {
		my $xml = XML::Bare->new(text => $res->decoded_content);
		my $tree = $xml->parse()->{RimTabletResponse};
		return {
			logged_in => 0,
			auth_challenge => $tree->{AuthChallenge},
		};
	}
}

sub login {
	my ($self, $password) = @_;

	my $login_status = $self->logged_in;
	if ($login_status->{logged_in}) {
		say "Login session still valid.";
		return 1;
	}

	my $auth_challenge = $login_status->{auth_challenge};
	if ($auth_challenge->{RetriesRemaining} == 1) {
		die "One auth attempt remaining - refusing to continue with auth attempt";
	}

	say "Attempting login...";

	# <Status>PasswdChallenge</Status>
	# <Challenge>What's the airspeed velocity of an unladen swallow?3sk291pu0Vp3vGoFHqG2fJxfKK7r</Challenge>
	# <Algorithm>2</Algorithm>
	# <Salt>CF488F2B5A5AB853</Salt>
	# <ICount>5940</ICount>
	# <FailedAttempts>0</FailedAttempts>
	# <RetriesRemaining>5</RetriesRemaining>

	my $challenge_response = $self->hash_pass({
		challenge => $auth_challenge->{Challenge}->{value},
		salt => $auth_challenge->{Salt}->{value},
		count => $auth_challenge->{ICount}->{value},
		password => $password,
	});

	my $res = $ua->get("https://$self->{ip}/cgi-bin/login.cgi?challenge_data=$challenge_response&request_version=3");
	if (!$res->is_success) {
		say $res->status_line;
		return;
	}

	if (xml_status($res->decoded_content, 'Auth') eq 'Success') {
		say "Logged in.";
		return 1;
	} else {
		say $res->decoded_content;
		die "Login failed.";
	}
}

sub hash_pass {
	my ($self, $props) = @_;
	die "bad args to hash_pass" unless $props->{challenge} && $props->{salt} && $props->{count} && $props->{password};
	my $salt = pack('H16', $props->{salt});

	my $hashdata = $props->{password};
	for (my $count = 0; $count < $props->{count}; $count++) {
		$hashdata = sha512(pack('l<', $count) . $salt . $hashdata);
	}
	$hashdata = $props->{challenge} . $hashdata;
	for (my $count = 0; $count < $props->{count}; $count++) {
		$hashdata = sha512(pack('l<', $count) . $salt . $hashdata);
	}
	return uc unpack('H128', $hashdata);
}

sub backup_list {
	my ($self) = @_;

	say "Fetching backup list...";

	my $res = $ua->post("https://$self->{ip}/cgi-bin/backup.cgi", {
		query => 'list',
		opt => 'rev2',
	});
	if (!$res->is_success) {
		say $res->decoded_content;
		return;
	}

	my $xml = XML::Bare->new(text => $res->decoded_content);
	my $tree = $xml->parse()->{RimTabletResponse};

	return $tree;
}

sub backup {
	my ($self, $options, @items) = @_;

	my $packages_xml = '<Packages>';
	for my $f (@items) {
		$packages_xml .= qq{<Package category="$f->{category}" pkgid="$f->{pkgid}" type="$f->{type}" />};
	}
	$packages_xml .= '</Packages>';

	say STDERR "Beginning backup...";
	for (1..10) {
		my $uri = URI->new("https://$self->{ip}/cgi-bin/backup.cgi");
		$uri->query_form({
			mode => 'app_media_settings',
			opt => 'rev2',
		});
		my $req = POST $uri->as_string;
		$req->content($packages_xml);
		$req->header('Content-Length', length($packages_xml));
		my $res = $ua->request($req);
		if (!$res->is_success) {
			say $res->decoded_content;
			return;
		} 

		if (xml_status($res->decoded_content, 'BackupStart') eq 'Success') {
			last;
		}
	}

	mkdir $options->{dir};
	mkdir "$options->{dir}/Archive";

	open MANIFEST, '>', "$options->{dir}/Manifest.xml";
	print MANIFEST <<'HEAD';
<?xml version="1.0" encoding="UTF-8"?>
<BlackBerry_Backup>
  <Version>4.0</Version>
  <Client dtmversion="1.2.4.39" osversion="Microsoft Windows NT 6.2.9200.0" platform="windows"/>
  <QnxOSDevice>
    <Archives>
HEAD

	my $preparation_status;
	for (1..10) {
		my $res = $ua->post("https://$self->{ip}/cgi-bin/backup.cgi", {
			query => 'activity',
		});
		if (!$res->is_success) {
			say $res->decoded_content;
			return;
		}
		say "Waiting for backup to start...";

		my ($status, $response) = xml_status($res->decoded_content, 'BackupStartActivity');
		if ($status eq 'Error') {
			say $res->decoded_content;
			die "Error beginning backup";
		}
		if ($status ne 'InProgress') {
			say "Backup starting. Total size: $response->{TotalSize}->{value}";
			last;
		}
		sleep 1;
	}

	for my $f (@items) {
		my $backup_uri = URI->new("https://$self->{ip}/cgi-bin/backup.cgi");
		my %query;
		if ($f->{pkgid} eq 'systemapps' || $f->{type} ~~ ['bin', 'data']) {
			$query{type} = 'app';
			if ($f->{type} ~~ ['bin', 'data']) {
				$query{pkgid} = $f->{pkgid};
				$query{pkgtype} = $f->{type};
			}
		} elsif ($f->{pkgid} eq 'media') {
			$query{type} = 'media';
		} elsif ($f->{pkgid} eq 'settings') {
			$query{type} = 'settings';
		} else {
			die "Unknown backup type for $f->{pkgid}";
		}
		$backup_uri->query_form(\%query);

		my $res = $ua->get($backup_uri->as_string, ':content_file' => "$options->{dir}/Archive/$f->{pkgid}.$f->{category}.$f->{type}");
		if (!$res->is_success) {
			say $res->decoded_content;
			return;
		}

		$res = $ua->post($backup_uri->as_string, { opt => 'rev2' });
		if (!$res->is_success) {
			say $res->decoded_content;
			return;
		}

		if (xml_status($res->decoded_content, 'BackupCheck') eq 'Error') {
			say $res->decoded_content;
			die "Error fetching $f->{name}";
		}
		say "Probably fetched $f->{name} $f->{type}";

		print MANIFEST ' ' x 6, qq{<Archive name="$f->{name}" id="$f->{pkgid}" type="$f->{type}" bytesize="$f->{bytesize}" count="$f->{count}" detail="$f->{detail}" version="$f->{version}" keyid="$options->{keyid}" />\n};
	}

	print MANIFEST <<'FOOT';
    </Archives>
  </QnxOSDevice>
</BlackBerry_Backup>
FOOT
}

sub restore {
	my ($self, $options, @archives) = @_;

	my $total_size = 0;
	for my $f (@archives) {
		$total_size += -s $f->{file};
	}

	my $res = $ua->post("https://$self->{ip}/cgi-bin/backup.cgi", {
		action => 'restore',
		mode => 'app_media_settings',
		totalsize => $total_size,
		opt => 'rev2',
	});
	if (!$res->is_success) {
		say $res->decoded_content;
		return;
	}

	if (xml_status($res->decoded_content, 'RestoreStart') eq 'Error') {
		say $res->decoded_content;
		die "Error beginning restore";
	}

	for my $f (@archives) {
		say "Restoring $f->{file}";
		open FILE, $f->{file};

		my $restore_uri = URI->new("https://$self->{ip}/cgi-bin/backup.cgi");
		my %query = (
			action => 'restore',
			size => $total_size,
			opt => 'rev2',
		);
		if ($f->{id} eq 'systemapps' || $f->{type} ~~ ['bin', 'data']) {
			$query{type} = 'app';
			if ($f->{type} ~~ ['bin', 'data']) {
				$query{pkgid} = $f->{id};
				$query{pkgtype} = $f->{type};
			}
		} elsif ($f->{id} eq 'media') {
			$query{type} = 'media';
		} elsif ($f->{id} eq 'settings') {
			$query{type} = 'settings';
		} else {
			die "Unknown backup type for $f->{id}";
		}
		$restore_uri->query_form(\%query);

		my $req = POST $restore_uri->as_string;
		$req->headers->header(
			Content_Type => 'application/octet-stream',
			Content_Length => -s $f->{file},
		);
		$req->content(sub {
			return "" if eof FILE;

			my $chunk;
			read(FILE, $chunk, 16384);
			return $chunk;
		});

		$res = $ua->request($req);
		if ($res->code != 200) {
			say $res->code, ' ', $res->decoded_content;
		} else {
			say "  OK!";
		}
		close FILE;
	}

	say "Completing restore...";
	$res = $ua->post("https://$self->{ip}/cgi-bin/backup.cgi", {
		action => 'restore',
		status => 'success',
		opt => 'rev2',
	});

	say $res->code, ' ', $res->decoded_content;
	say "Done.";
}

1;
