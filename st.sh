# CLI Tools

# Another git viewer
cd ~/Downloads
VERSION=0.41.0   # change to latest
curl -Lo lazygit.tar.gz https://github.com/jesseduffield/lazygit/releases/download/v${VERSION}/lazygit_${VERSION}_Linux_x86_64.tar.gz
tar xf lazygit.tar.gz lazygit
sudo install lazygit /usr/local/bin

# To read md files
sudo dnf -y install glow

# top/htop alternative
sudo dnf install btop

# image viewer
sudo dnf install chafa

# csv viewer
cargo install csvlens

# ls alternative
cargo install eza
echo "alias eza='eza --grid --group-directories-first'" >> ~/.bashrc

# Curve fitting library
pip3 install lmfit

# check LLM fit
curl -fsSL https://llmfit.axjns.dev/install.sh | sh

# AI Models comparison
cd ~/Downloads
git clone https://github.com/arimxyer/models
cd models
cargo build --release
sudo cp ./target/release/models /usr/local/bin
sudo chmod +x /usr/local/bin/models

# Simple cd with history
curl -sSfL https://raw.githubusercontent.com/ajeetdsouza/zoxide/main/install.sh | sh
echo 'eval "$(zoxide init bash)"' >> ~/.bashrc
source ~/.bashrc

# Some fonts to install
mkdir -p ~/.local/share/fonts/jetbrain-fonts
cd ~/.local/share/fonts/jetbrain-fonts
wget https://github.com/ryanoasis/nerd-fonts/releases/latest/download/JetBrainsMono.zip
unzip JetBrainsMono.zip
fc-cache -fv

mkdir -p ~/.local/share/fonts/nerd-fonts
cd ~/.local/share/fonts/nerd-fonts
wget https://github.com/ryanoasis/nerd-fonts/releases/download/v2.3.3/SourceCodePro.zip
unzip SourceCodePro.zip
fc-cache -fv


