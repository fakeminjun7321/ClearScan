import UIKit

extension UIViewController {
  func presentError(_ error: Error, title: String = "문제가 발생했어요") {
    let alert = UIAlertController(
      title: title,
      message: error.localizedDescription,
      preferredStyle: .alert
    )
    alert.addAction(UIAlertAction(title: "확인", style: .default))
    present(alert, animated: true)
  }

  func presentMessage(title: String, message: String) {
    let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
    alert.addAction(UIAlertAction(title: "확인", style: .default))
    present(alert, animated: true)
  }
}

final class StoredImageView: UIImageView {
  private var representedPath: String?

  init() {
    super.init(frame: .zero)
    backgroundColor = .secondarySystemBackground
    contentMode = .scaleAspectFill
    clipsToBounds = true
    layer.cornerRadius = 9
    image = UIImage(systemName: "doc")
    tintColor = .secondaryLabel
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  func load(path: String?, from store: ScanImageReading) {
    representedPath = path
    image = UIImage(systemName: "doc")
    guard let path else { return }

    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
      let loadedImage = (try? store.data(for: path)).flatMap(UIImage.init(data:))
      DispatchQueue.main.async {
        guard let self, self.representedPath == path else { return }
        self.image = loadedImage ?? UIImage(systemName: "doc")
      }
    }
  }
}

final class ThumbnailSubtitleCell: UITableViewCell {
  static let reuseIdentifier = "ThumbnailSubtitleCell"

  let storedImageView = StoredImageView()
  let titleLabel = UILabel()
  let subtitleLabel = UILabel()
  let badgeLabel = UILabel()

  override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
    super.init(style: style, reuseIdentifier: reuseIdentifier)
    accessoryType = .disclosureIndicator

    storedImageView.translatesAutoresizingMaskIntoConstraints = false
    titleLabel.font = .preferredFont(forTextStyle: .headline)
    titleLabel.numberOfLines = 2
    subtitleLabel.font = .preferredFont(forTextStyle: .caption1)
    subtitleLabel.textColor = .secondaryLabel
    badgeLabel.font = .preferredFont(forTextStyle: .caption2)
    badgeLabel.textColor = .systemBlue

    let labels = UIStackView(arrangedSubviews: [titleLabel, subtitleLabel, badgeLabel])
    labels.axis = .vertical
    labels.spacing = 3
    labels.translatesAutoresizingMaskIntoConstraints = false

    contentView.addSubview(storedImageView)
    contentView.addSubview(labels)
    NSLayoutConstraint.activate([
      storedImageView.leadingAnchor.constraint(
        equalTo: contentView.layoutMarginsGuide.leadingAnchor),
      storedImageView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 10),
      storedImageView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -10),
      storedImageView.widthAnchor.constraint(equalToConstant: 54),
      storedImageView.heightAnchor.constraint(equalToConstant: 70),

      labels.leadingAnchor.constraint(equalTo: storedImageView.trailingAnchor, constant: 13),
      labels.trailingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.trailingAnchor),
      labels.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
    ])
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func prepareForReuse() {
    super.prepareForReuse()
    titleLabel.text = nil
    subtitleLabel.text = nil
    badgeLabel.text = nil
    storedImageView.load(path: nil, from: EmptyImageReader.shared)
  }
}

private final class EmptyImageReader: ScanImageReading {
  static let shared = EmptyImageReader()
  func data(for relativePath: String) throws -> Data { Data() }
  func fileURL(for relativePath: String) throws -> URL { URL(fileURLWithPath: "/") }
}
