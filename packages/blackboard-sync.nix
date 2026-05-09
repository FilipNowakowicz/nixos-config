{ pkgs }:
let
  python = pkgs.python3;
  ps = python.pkgs;

  tiny-api-client = ps.buildPythonPackage rec {
    pname = "tiny-api-client";
    version = "1.4.0";
    pyproject = true;
    src = ps.fetchPypi {
      pname = "tiny_api_client";
      inherit version;
      hash = "sha256-rWdythHfxxU1gA0NuQElj4sNpqx34npxJg6upQfmntM=";
    };
    build-system = with ps; [
      setuptools
      setuptools-scm
    ];
    dependencies = [ ps.requests ];
    doCheck = false;
  };

  bblearn = ps.buildPythonPackage rec {
    pname = "bblearn";
    version = "0.3.6";
    pyproject = true;
    src = ps.fetchPypi {
      inherit pname version;
      hash = "sha256-Q7r9Llqdsn8kmAB5wYagJTBH0l4TgpbLxzCo/+iWmOc=";
    };
    build-system = with ps; [
      setuptools
      setuptools-scm
    ];
    dependencies = with ps; [
      pathvalidate
      pydantic
      requests
      tiny-api-client
      typing-extensions
      tzdata
    ];
    doCheck = false;
  };

  bwfilters = ps.buildPythonPackage rec {
    pname = "bwfilters";
    version = "0.1.0";
    pyproject = true;
    src = ps.fetchPypi {
      inherit pname version;
      hash = "sha256-B/UzUsiw3+OmFemC8G1ZXporc/7wG4dilJS+kbbJRhA=";
    };
    build-system = with ps; [
      setuptools
      setuptools-scm
    ];
    dependencies = [ ps.typing-extensions ];
    doCheck = false;
  };

  whoisit = ps.buildPythonPackage rec {
    pname = "whoisit";
    version = "4.0.3";
    pyproject = true;
    src = ps.fetchPypi {
      inherit pname version;
      hash = "sha256-EErKoZNI2nHOceyXyDErPuVD59zEr14sjyK00vkRXsQ=";
    };
    build-system = [ ps.setuptools ];
    dependencies = with ps; [
      httpx
      python-dateutil
      requests
      typing-extensions
      urllib3
    ];
    doCheck = false;
  };

in
ps.buildPythonApplication rec {
  pname = "blackboardsync";
  version = "0.18.0";
  pyproject = true;

  src = ps.fetchPypi {
    inherit pname version;
    hash = "sha256-PkmaewWFXgIO00F7ugkTeajuWNDyDA7qlPmOCfaD0VQ=";
  };

  build-system = with ps; [
    setuptools
    setuptools-scm
  ];

  dependencies = with ps; [
    appdirs
    bblearn
    beautifulsoup4
    bwfilters
    lxml
    packaging
    pathvalidate
    pydantic
    pyqt6
    pyqt6-webengine
    python-dateutil
    requests
    whoisit
  ];

  nativeBuildInputs = [ pkgs.qt6.wrapQtAppsHook ];

  buildInputs = [ pkgs.qt6.qtbase ];

  dontWrapQtApps = false;

  meta = {
    description = "Blackboard Learn course content sync tool";
    mainProgram = "blackboardsync";
  };
}
