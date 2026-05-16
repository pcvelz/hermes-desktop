(function () {
  const readyMessage = 'terminalReady';
  const inputMessage = 'terminalInput';
  const binaryMessage = 'terminalBinary';
  const resizeMessage = 'terminalResize';

  let term = null;
  let fitAddon = null;
  let resizeObserver = null;
  let fitTimer = null;
  let baselineViewportHeight = 0;
  const baseTheme = {
    background: '#09111a',
    foreground: '#edf1f7',
    cursor: '#57d7be',
    cursorAccent: '#09111a',
    selectionBackground: 'rgba(90, 191, 166, 0.28)',
    black: '#09111a',
    red: '#ff6b7d',
    green: '#5fd78d',
    yellow: '#f5d76e',
    blue: '#7ab6ff',
    magenta: '#c08bff',
    cyan: '#63d7df',
    white: '#edf1f7',
    brightBlack: '#5a6777',
    brightRed: '#ff8f9d',
    brightGreen: '#7ef0a9',
    brightYellow: '#ffe58b',
    brightBlue: '#99cbff',
    brightMagenta: '#d8b2ff',
    brightCyan: '#8be8ef',
    brightWhite: '#ffffff'
  };
  let currentTheme = { ...baseTheme };

  function post(name, payload) {
    if (
      window.webkit &&
      window.webkit.messageHandlers &&
      window.webkit.messageHandlers[name]
    ) {
      window.webkit.messageHandlers[name].postMessage(payload);
    }
  }

  function viewportMetrics() {
    const container = document.getElementById('terminal-surface');
    const width = container ? container.clientWidth : 0;
    const height = container ? container.clientHeight : 0;
    const scale = window.devicePixelRatio || 1;

    return {
      cols: term ? term.cols : 80,
      rows: term ? term.rows : 24,
      pixelWidth: Math.max(0, Math.floor(width * scale)),
      pixelHeight: Math.max(0, Math.floor(height * scale))
    };
  }

  function notifyReady() {
    post(readyMessage, viewportMetrics());
  }

  function notifyResize() {
    post(resizeMessage, viewportMetrics());
  }

  function scheduleFit() {
    clearTimeout(fitTimer);
    fitTimer = setTimeout(() => {
      refreshLayout(3);
    }, 40);
  }

  function isKeyboardVisible() {
    return document.documentElement.classList.contains('keyboard-visible');
  }

  function isTerminalFocused() {
    return !!(term && term.textarea && document.activeElement === term.textarea);
  }

  function shouldPinViewportToBottom() {
    return isKeyboardVisible() || isTerminalFocused();
  }

  function pinViewportToBottom() {
    if (!term || !shouldPinViewportToBottom()) {
      return;
    }

    window.requestAnimationFrame(() => {
      term.scrollToBottom();
    });
  }

  function syncKeyboardClass() {
    if (!window.visualViewport) {
      return;
    }

    if (!baselineViewportHeight) {
      baselineViewportHeight = window.visualViewport.height;
    }

    const keyboardVisible = baselineViewportHeight - window.visualViewport.height > 120;
    document.documentElement.classList.toggle('keyboard-visible', keyboardVisible);
  }

  function decodeBase64(base64) {
    const binary = atob(base64);
    const bytes = new Uint8Array(binary.length);
    for (let index = 0; index < binary.length; index += 1) {
      bytes[index] = binary.charCodeAt(index);
    }
    return bytes;
  }

  function isAlternateScreenActive() {
    if (!term || !term.buffer) {
      return false;
    }

    if (
      term.buffer.active &&
      term.buffer.normal &&
      term.buffer.active !== term.buffer.normal
    ) {
      return true;
    }

    return term.buffer.active && term.buffer.active.type === 'alternate';
  }

  function sanitizeOutboundData(data) {
    if (!data) {
      return '';
    }

    if (isAlternateScreenActive()) {
      return data;
    }

    let sanitized = data;
    sanitized = sanitized.replace(/\u001b\](10|11|12);rgb:[0-9a-fA-F/]+(?:\u0007|\u001b\\)/g, '');
    sanitized = sanitized.replace(/\u001b\[(?:\?|>)[0-9;]*c/g, '');
    sanitized = sanitized.replace(/\u001b\[[0-9;]*R/g, '');
    sanitized = sanitized.replace(/\u001b\[[0-9;]*n/g, '');
    sanitized = sanitized.replace(/\u001b\[[0-9;]*t/g, '');
    sanitized = sanitized.replace(/\u001b\[[IO]/g, '');
    return sanitized;
  }

  function rgbaFromHex(hex, alpha) {
    if (!hex || typeof hex !== 'string') {
      return `rgba(90, 191, 166, ${alpha})`;
    }

    const normalized = hex.replace('#', '');
    if (normalized.length !== 6) {
      return `rgba(90, 191, 166, ${alpha})`;
    }

    const red = parseInt(normalized.slice(0, 2), 16);
    const green = parseInt(normalized.slice(2, 4), 16);
    const blue = parseInt(normalized.slice(4, 6), 16);
    return `rgba(${red}, ${green}, ${blue}, ${alpha})`;
  }

  function applyTheme(themePatch) {
    currentTheme = {
      ...currentTheme,
      ...themePatch
    };

    currentTheme.cursor = currentTheme.foreground;
    currentTheme.cursorAccent = currentTheme.background;
    currentTheme.selectionBackground = rgbaFromHex(currentTheme.foreground, 0.28);

    document.documentElement.style.setProperty('--terminal-background', currentTheme.background);
    document.documentElement.style.setProperty('--terminal-foreground', currentTheme.foreground);
    document.documentElement.style.setProperty('--terminal-selection', currentTheme.selectionBackground);
    document.documentElement.style.setProperty('--terminal-cursor', currentTheme.cursor);

    if (term) {
      term.options.theme = { ...currentTheme };
      if (term.element) {
        term.element.style.backgroundColor = currentTheme.background;
        term.element.style.color = currentTheme.foreground;
      }
      refreshLayout(2);
    }
  }

  function performFit() {
    if (!term || !fitAddon) {
      return false;
    }

    const container = document.getElementById('terminal-surface');
    if (!container || container.clientWidth <= 0 || container.clientHeight <= 0) {
      return false;
    }

    fitAddon.fit();
    notifyResize();
    pinViewportToBottom();
    return true;
  }

  function refreshLayout(iterations = 4) {
    let remaining = Math.max(1, iterations);

    function tick() {
      performFit();
      remaining -= 1;
      if (remaining <= 0) {
        return;
      }

      window.requestAnimationFrame(() => {
        setTimeout(tick, remaining > 1 ? 50 : 90);
      });
    }

    tick();
  }

  function mountTerminal() {
    const container = document.getElementById('terminal-surface');
    if (!container || !window.Terminal || !window.FitAddon) {
      return;
    }

    term = new window.Terminal({
      allowTransparency: false,
      convertEol: false,
      cursorBlink: true,
      cursorInactiveStyle: 'outline',
      cursorStyle: 'block',
      fontFamily: 'SFMono-Regular, Menlo, Monaco, Consolas, "Liberation Mono", monospace',
      fontSize: 15,
      fontWeight: '400',
      fontWeightBold: '600',
      lineHeight: 1.12,
      macOptionIsMeta: true,
      minimumContrastRatio: 1,
      overviewRulerWidth: 0,
      rightClickSelectsWord: true,
      scrollback: 10000,
      scrollSensitivity: 1,
      tabStopWidth: 4,
      theme: currentTheme
    });

    fitAddon = new window.FitAddon.FitAddon();
    term.loadAddon(fitAddon);
    term.open(container);
    applyTheme(currentTheme);

    term.onData((data) => {
      const sanitized = sanitizeOutboundData(data);
      if (sanitized.length > 0) {
        post(inputMessage, { data: sanitized });
      }
    });

    term.onBinary((data) => {
      post(binaryMessage, { data: data });
    });

    term.onResize(() => {
      notifyResize();
    });

    resizeObserver = new ResizeObserver(() => {
      scheduleFit();
    });
    resizeObserver.observe(container);

    if (window.visualViewport) {
      baselineViewportHeight = window.visualViewport.height;
      window.visualViewport.addEventListener('resize', () => {
        syncKeyboardClass();
        scheduleFit();
      });
    }

    window.addEventListener('orientationchange', scheduleFit);
    syncKeyboardClass();

    requestAnimationFrame(() => {
      refreshLayout(4);
      requestAnimationFrame(() => {
        notifyReady();
        term.focus();
      });
    });
  }

  window.HermesTerminal = {
    blur() {
      if (term) {
        term.blur();
      }
    },
    focus() {
      if (term) {
        term.focus();
        pinViewportToBottom();
      }
    },
    reset() {
      if (term) {
        term.reset();
      }
    },
    clear() {
      if (term) {
        term.clear();
      }
    },
    scrollToBottom() {
      if (term) {
        term.scrollToBottom();
        window.requestAnimationFrame(() => {
          term.scrollToBottom();
        });
        setTimeout(() => {
          term.scrollToBottom();
        }, 120);
        setTimeout(() => {
          term.scrollToBottom();
        }, 280);
      }
    },
    fit() {
      refreshLayout(4);
    },
    refreshLayout() {
      refreshLayout(4);
    },
    setTheme(theme) {
      applyTheme(theme || {});
    },
    writeBase64(base64) {
      if (!term) {
        return;
      }
      term.write(decodeBase64(base64));
    }
  };

  document.addEventListener('DOMContentLoaded', mountTerminal);
})();
